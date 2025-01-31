// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/utils/ReentrancyGuard.sol';

import {ISavingCircles} from '../interfaces/ISavingCircles.sol';

/**
 * @title Saving Circles
 * @notice Simple implementation of a rotating savings and credit association (ROSCA) for ERC20 tokens
 * @author Breadchain Collective
 * @author @RonTuretzky
 * @author bagelface.eth
 */
contract SavingCircles is ISavingCircles, ReentrancyGuard, OwnableUpgradeable {
  uint256 public constant MINIMUM_MEMBERS = 2;

  uint256 public nextId;
  mapping(uint256 id => Circle circle) public circles;
  mapping(uint256 id => mapping(address token => uint256 balance)) public balances;
  mapping(uint256 id => mapping(address member => bool status)) public isMember;
  mapping(address member => uint256[] ids) public memberCircles;
  mapping(address token => bool status) public allowedTokens;

  /**
   * @dev Requires circle is commissioned by checking if an owner is set
   */
  modifier circleDecomissioned(uint256 _id) {
    if (_isDecommissioned(circles[_id])) revert NotCommissioned();
    _;
  }

  /**
   * @dev Requires address is a member by checking the mapping
   */
  modifier notMember(uint256 _id) {
    if (!isMember[_id][msg.sender]) revert NotMember();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address _owner) external override initializer {
    __Ownable_init_unchained(_owner);
  }

  /**
   * @notice Create a new saving circle
   * @param _circle A new saving circle
   */
  function create(Circle memory _circle) external override returns (uint256 _id) {
    _id = nextId++;

    if (circles[_id].owner != address(0)) revert AlreadyExists();
    if (!allowedTokens[_circle.token]) revert TokenNotAllowed();
    if (_circle.depositInterval == 0) revert InvalidDepositInterval();
    if (_circle.depositAmount == 0) revert InvalidDepositAmount();
    if (_circle.maxDeposits == 0) revert InvalidMaxDeposits();
    if (_circle.circleStart == 0) revert InvalidCircleStartTime();
    if (_circle.currentIndex != 0) revert InvalidCurrentIndex();
    if (_circle.owner == address(0)) revert InvalidOwner();
    if (_circle.members.length < MINIMUM_MEMBERS) revert InvalidMemberCount();

    for (uint256 i = 0; i < _circle.members.length; i++) {
      address _member = _circle.members[i];
      if (_member == address(0)) revert InvalidMemberAddress();
      isMember[_id][_member] = true;
      memberCircles[_member].push(_id);
    }

    circles[_id] = _circle;

    emit CircleCreated(_id, _circle.members, _circle.token, _circle.depositAmount, _circle.depositInterval);

    return _id;
  }

  /**
   * @notice Make a deposit into a specified circle
   * @param _id Identifier of the circle
   * @param _value Amount of the token to deposit
   */
  function deposit(uint256 _id, uint256 _value) external override nonReentrant {
    _deposit(_id, _value, msg.sender);
  }

  /**
   * @notice Make a deposit on behalf of another member
   * @param _id Identifier of the circle
   * @param _value Amount of the token to deposit
   * @param _member Address to make a deposit for
   */
  function depositFor(uint256 _id, uint256 _value, address _member) external override nonReentrant {
    _deposit(_id, _value, _member);
  }

  /**
   * @notice Make a withdrawal from a specified circle
   * @param _id Identifier of the circle
   */
  function withdraw(uint256 _id) external override nonReentrant {
    _withdraw(_id, msg.sender);
  }

  /**
   * @notice Make a withdrawal from a specified circle on behalf of another member
   * @param _id Identifier of the circle
   * @param _member Address of the member to make a withdrawal for
   */
  function withdrawFor(uint256 _id, address _member) external override nonReentrant {
    _withdraw(_id, _member);
  }

  /**
   * @notice Set if a token can be used for saving circles
   * @param _token Token to update the status of
   * @param _allowed Can be used for saving circles
   */
  function setTokenAllowed(address _token, bool _allowed) external override onlyOwner {
    allowedTokens[_token] = _allowed;

    emit TokenAllowed(_token, _allowed);
  }

  /**
   * @notice Decommission an existing saving circle
   * @dev Returns all deposits to members
   * @param _id Identifier of the circle
   */
  function decommission(uint256 _id) external override {
    Circle storage _circle = circles[_id];

    if (_circle.owner != msg.sender) {
      if (!isMember[_id][msg.sender]) revert NotMember();
      if (block.timestamp <= _circle.circleStart + (_circle.depositInterval * (_circle.currentIndex + 1))) {
        revert NotDecommissionable();
      }

      bool hasIncompleteDeposits = false;
      for (uint256 i = 0; i < _circle.members.length; i++) {
        if (balances[_id][_circle.members[i]] < _circle.depositAmount) {
          hasIncompleteDeposits = true;
          break;
        }
      }
      if (!hasIncompleteDeposits) revert NotDecommissionable();
    }

    // Return deposits to members
    for (uint256 i = 0; i < _circle.members.length; i++) {
      address _member = _circle.members[i];
      uint256 _balance = balances[_id][_member];

      if (_balance > 0) {
        balances[_id][_member] = 0;
        bool success = IERC20(_circle.token).transfer(_member, _balance);
        if (!success) revert TransferFailed();
      }
    }

    delete circles[_id];

    emit CircleDecommissioned(_id);
  }

  /**
   * @notice Return if a token is allowed to be used for saving circles
   * @param _token Address of a token
   * @return bool Token allowed
   */
  function isTokenAllowed(address _token) external view override returns (bool) {
    return allowedTokens[_token];
  }

  /**
   * @notice Return the info of a specified saving circle
   * @param _id Identifier of the circle
   * @return _circle Saving circle
   */
  function getCircle(uint256 _id) external view override circleDecomissioned(_id) returns (Circle memory _circle) {
    _circle = circles[_id];
    return _circle;
  }

  /**
   * @notice Get multiple circles in a single call
   * @param _ids Array of circle IDs to fetch
   * @return _circles Array of circles
   */
  function getCircles(uint256[] calldata _ids) external view returns (Circle[] memory _circles) {
    _circles = new Circle[](_ids.length);

    for (uint256 i = 0; i < _ids.length; i++) {
      _circles[i] = circles[_ids[i]];
    }

    return _circles;
  }

  /**
   * @notice Get all circles for a specific member
   * @param _member Address of the member
   * @return _ids Array of circle IDs the member belongs to
   */
  function getMemberCircles(address _member) external view returns (uint256[] memory _ids) {
    return memberCircles[_member];
  }

  /**
   * @notice Return the balances of the members of a specified saving circle
   * @param _id Identifier of the circle
   * @return _members Members of the specified saving circle
   * @return _balances Corresponding balances of the members of the circle
   */
  function getMemberBalances(uint256 _id)
    external
    view
    override
    circleDecomissioned(_id)
    returns (address[] memory _members, uint256[] memory _balances)
  {
    Circle memory _circle = circles[_id];
    _balances = new uint256[](_circle.members.length);
    for (uint256 i = 0; i < _circle.members.length; i++) {
      _balances[i] = balances[_id][_circle.members[i]];
    }

    return (_circle.members, _balances);
  }

  /**
   * @notice Check membership status for multiple circles
   * @param _member Address to check
   * @param _ids Array of circle IDs to check
   * @return _statuses Array of boolean membership statuses
   */
  function checkMemberships(address _member, uint256[] calldata _ids) external view returns (bool[] memory _statuses) {
    _statuses = new bool[](_ids.length);

    for (uint256 i = 0; i < _ids.length; i++) {
      _statuses[i] = isMember[_ids[i]][_member];
    }

    return _statuses;
  }

  /**
   * @notice Return the member address which is currently able to withdraw from a specified circle
   * @param _id Identifier of the circle
   * @return address Member that is currently able to withdraw from the circle
   */
  function withdrawableBy(uint256 _id) external view override circleDecomissioned(_id) returns (address) {
    Circle memory _circle = circles[_id];
    return _circle.members[_circle.currentIndex];
  }

  /**
   * @notice Return if a circle can currently be withdrawn from
   * @param _id Identifier of the circle
   * @return bool If the circle is able to be withdrawn from
   */
  function isWithdrawable(uint256 _id) external view override returns (bool) {
    return _withdrawable(_id);
  }

  /**
   * @dev Make a withdrawal from a specified circle
   *      A withdrawal must be made by a member of the circle, even if it is for another member.
   */
  function _withdraw(uint256 _id, address _member) internal notMember(_id) {
    Circle storage _circle = circles[_id];

    if (!_withdrawable(_id)) revert NotWithdrawable();
    if (_circle.members[_circle.currentIndex] != _member) revert NotWithdrawable();
    if (_circle.currentIndex >= _circle.maxDeposits) revert NotWithdrawable();

    uint256 _withdrawAmount = _circle.depositAmount * (_circle.members.length);

    for (uint256 i = 0; i < _circle.members.length; i++) {
      balances[_id][_circle.members[i]] = 0;
    }

    _circle.currentIndex = (_circle.currentIndex + 1) % _circle.members.length;
    bool success = IERC20(_circle.token).transfer(_member, _withdrawAmount);
    if (!success) revert TransferFailed();

    emit FundsWithdrawn(_id, _member, _withdrawAmount);
  }

  /**
   * @dev Make a deposit into a specified circle
   *      A deposit must be made in specific time window and can be made partially so long as the final balance equals
   *      the specified deposit amount for the circle.
   */
  function _deposit(uint256 _id, uint256 _value, address _member) internal circleDecomissioned(_id) notMember(_id) {
    Circle memory _circle = circles[_id];

    if (block.timestamp < circles[_id].circleStart) {
      revert DepositBeforeCircleStart();
    }
    if (block.timestamp >= circles[_id].circleStart + (circles[_id].depositInterval * (circles[_id].currentIndex + 1)))
    {
      revert DepositWindowClosed();
    }
    if (block.timestamp >= circles[_id].circleStart + (circles[_id].depositInterval * circles[_id].maxDeposits)) {
      revert CircleExpired();
    }
    if (balances[_id][_member] + _value > circles[_id].depositAmount) {
      revert ExceedsDepositAmount();
    }

    balances[_id][_member] = balances[_id][_member] + _value;

    bool success = IERC20(_circle.token).transferFrom(msg.sender, address(this), _value);
    if (!success) revert TransferFailed();

    emit FundsDeposited(_id, _member, _value);
  }

  /**
   * @dev Return if a specified circle is withdrawable
   *      To be considered withdrawable, enough time must have passed since the deposit interval started
   *      and all members must have made a deposit.
   */
  function _withdrawable(uint256 _id) internal view circleDecomissioned(_id) returns (bool) {
    Circle memory _circle = circles[_id];

    if (block.timestamp < _circle.circleStart + (_circle.depositInterval * _circle.currentIndex)) {
      return false;
    }

    for (uint256 i = 0; i < _circle.members.length; i++) {
      if (balances[_id][_circle.members[i]] < _circle.depositAmount) {
        return false;
      }
    }

    return true;
  }

  /**
   * @dev Return if a specified circle is decommissioned by checking if an owner is set
   */
  function _isDecommissioned(Circle memory _circle) internal pure returns (bool) {
    return _circle.owner == address(0);
  }
}
