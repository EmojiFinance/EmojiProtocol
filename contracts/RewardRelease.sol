pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RewardRelease {
    using SafeERC20 for IERC20;

    struct LockInfo {
        uint startTs;
        uint amount;
    }

    struct UserInfo {
        uint totalAmount;
        uint totalClaimed;
        LockInfo[] locks;
    }

    address public immutable token;

    address public operator;
    mapping(address => bool) isVault;
    mapping(address => UserInfo) public infos;

    constructor(address _token) {
        token = _token;
        operator = msg.sender;
    }

    modifier onlyOperator {
        require(msg.sender == operator);

        _;
    }

    function setOperator(address _op) public onlyOperator {
        operator = _op;
    } 

    function setVault(address _vault, bool _set) public onlyOperator {
        isVault[_vault] = _set;
    }

    function release(address _user, uint _amount) external {
        require(isVault[msg.sender], "vault");
        UserInfo storage user = infos[_user];
        uint lockSize = user.locks.length;
        if (lockSize == 0 
            || user.locks[lockSize - 1].startTs > block.timestamp - 1800) {
            user.locks.push(LockInfo(block.timestamp, _amount));
        } else {
            user.locks[lockSize - 1].amount += _amount;
        }
        user.totalAmount += _amount;
        user.totalClaimed += _amount / 90;
        IERC20(token).safeTransfer(_user, _amount / 90);
    }

    function getTotalReward(address _user) public view returns (uint) {
        UserInfo memory user = infos[_user];
        return user.totalAmount - user.totalClaimed;
    }

    function getClaimable(address _user) public view returns (uint) {
        UserInfo memory user = infos[_user];
        uint lockSize = user.locks.length;
        uint ret;
        for (uint i = 0; i < lockSize; i++) {
            LockInfo memory lock = user.locks[i];
            uint a = lock.amount * (block.timestamp - lock.startTs) / (2 * 24 * 3600) / 90;
            if (a > lock.amount) { a = lock.amount; }
            ret += a;
        }
        return ret - user.totalClaimed;
    }

    function claim() external {
        uint amount = getClaimable(msg.sender);
        if (amount > 0) {
            infos[msg.sender].totalClaimed += amount;
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }



}
