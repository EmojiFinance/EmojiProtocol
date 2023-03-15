pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


import "./interface/ICurve.sol";
import "./interface/IEquillRouter.sol";

import "./interface/IRewardRelease.sol";



contract KavaCurveThreePoolVault {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount; 
        uint256 rewardDebt; 
        uint256 pending;
    }

    address public immutable crv3pool = 0x7A0e3b70b1dB0D6CA63Cac240895b2D21444A7b9;
    address public immutable crv3poolGauge = 0x8004216BED6B6A8E6653ACD0d45c570ed712A632;
    address public immutable wkava = 0xc86c7C0eFbd6A49B35E8714C5f59D99De09A225b;
    address public immutable usdc = 0xfA9343C3897324496A05fC75abeD6bAC29f8A40f;
    address public immutable router = 0xA7544C409d772944017BB95B99484B6E0d7B6388;

    address public immutable rewarder;

    mapping(address => UserInfo) public userInfo;
    mapping(address => uint) public lastDepositTs;
    uint public totalShareAmount;

    address public operator;
    address public feeReceiver;

    uint256 public curRewardRate;
    uint256 public lastRewardUpdateTs; 
    uint256 public accRewardPerShare; 

    uint256 public lastReinvestTs;
    uint256 public performanceFeeRatio;  // base 100
    uint256 public withdrawFeeRatio;  // base 1000
    uint256 public withdrawFreePeriod;
    
    constructor (
        address _feeReceiver,
        address _rewarder
    ) {      
        operator = msg.sender;
        feeReceiver = _feeReceiver;
        rewarder = _rewarder;
    }

    modifier onlyOperator {
        require(msg.sender == operator);

        _;
    }

    function setOperator(address _op) public onlyOperator {
        operator = _op;
    } 

    function setFeeReceiver(address _addr) public onlyOperator {
        feeReceiver = _addr;
    }

    function setFee(uint _pfee, uint _wfee, uint _wp) public onlyOperator {
        require(_pfee <= 10);
        require(_wfee <= 5);
        require(_wp <= 3 * 24 * 3600);
        performanceFeeRatio = _pfee;
        withdrawFeeRatio = _wfee;
        withdrawFreePeriod = _wp;
    }

    function setRewardRate(uint _rate) public onlyOperator {
        require(_rate * 24 * 3600 <= 2000e18);
        _updateReward();
        curRewardRate = _rate;
    }

    function _updateReward() internal {
        if (totalShareAmount > 0) {
            accRewardPerShare += curRewardRate * (block.timestamp - lastRewardUpdateTs) * 10e12 / totalShareAmount;
        }
        lastRewardUpdateTs = block.timestamp;
        
    }


    function deposit(uint amount) public {
        reinvest();

        UserInfo storage user = userInfo[msg.sender];

        uint shareAmount;
        uint beforeBal = IERC20(crv3poolGauge).balanceOf(address(this));
        
        if (totalShareAmount == 0) {
            shareAmount = amount;
        } else {
            shareAmount = amount * totalShareAmount / beforeBal;
        }

        IERC20(crv3pool).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(crv3pool).approve(crv3poolGauge, amount);
        ICurveGauge(crv3poolGauge).deposit(amount);

        _updateReward();

        user.pending += accRewardPerShare * user.amount / 10e12 - user.rewardDebt;
        user.amount += shareAmount;
        user.rewardDebt = user.amount * accRewardPerShare / 1e12;

        totalShareAmount += shareAmount;
        lastDepositTs[msg.sender] = block.timestamp;
        
    }
    

    function withdraw(uint amount) public {
        reinvest();
        UserInfo storage user = userInfo[msg.sender];

        uint shareAmount;
        uint beforeBal = IERC20(crv3poolGauge).balanceOf(address(this));
        

        shareAmount = amount * totalShareAmount / beforeBal;
        require(shareAmount <= user.amount);

        ICurveGauge(crv3poolGauge).withdraw(amount);
        if (lastDepositTs[msg.sender] > block.timestamp - withdrawFreePeriod) {
            uint fee = amount * withdrawFeeRatio / 1000;
            IERC20(crv3pool).safeTransfer(feeReceiver, fee);
            IERC20(crv3pool).safeTransfer(msg.sender, amount - fee);
        } else {
            IERC20(crv3pool).safeTransfer(msg.sender, amount);
        }

        _updateReward();

        user.pending += accRewardPerShare * user.amount / 10e12 - user.rewardDebt;
        user.amount -= shareAmount;
        user.rewardDebt = user.amount * accRewardPerShare / 1e12;

        totalShareAmount -= shareAmount;

    }

    function withdrawAll() public {
        reinvest();
        UserInfo storage user = userInfo[msg.sender];

        uint shareAmount = user.amount;
        require(shareAmount > 0);

        uint beforeBal = IERC20(crv3poolGauge).balanceOf(address(this));
        uint amount = shareAmount * beforeBal / totalShareAmount;

        ICurveGauge(crv3poolGauge).withdraw(amount);
        if (lastDepositTs[msg.sender] > block.timestamp - withdrawFreePeriod) {
            uint fee = amount * withdrawFeeRatio / 1000;
            IERC20(crv3pool).safeTransfer(feeReceiver, fee);
            IERC20(crv3pool).safeTransfer(msg.sender, amount - fee);
        } else {
            IERC20(crv3pool).safeTransfer(msg.sender, amount);
        }

        _updateReward();

        user.pending += accRewardPerShare * user.amount / 10e12 - user.rewardDebt;
        user.amount = 0;
        user.rewardDebt = 0;
        totalShareAmount -= shareAmount;
    }

    function getBalance(address user) public view returns (uint256) {
        uint shareAmount = userInfo[user].amount;
        if (shareAmount == 0) {
            return 0;
        }
        uint beforeBal = IERC20(crv3poolGauge).balanceOf(address(this));
        uint amount = shareAmount * beforeBal / totalShareAmount;

        return amount;
    }

    function pendingReward(address _user) public view returns (uint256) {
        if (totalShareAmount == 0) {
            return 0;
        }
        UserInfo memory user = userInfo[_user];
        return user.pending + user.amount * curRewardRate * (block.timestamp - lastRewardUpdateTs) / totalShareAmount;
    }

    function claimReward() public {
        UserInfo storage user = userInfo[msg.sender];

        _updateReward();

        user.pending += accRewardPerShare * user.amount / 10e12 - user.rewardDebt;
        user.rewardDebt = user.amount * accRewardPerShare / 1e12;

        if (user.pending > 0) {
            IRewardRelease(rewarder).release(msg.sender, user.pending);
            user.pending = 0;
        }
    }

    
    function reinvest() public {
        // claim reward
        ICurveGauge(crv3poolGauge).claim_rewards(address(this));
        uint wkavaBal = IERC20(wkava).balanceOf(address(this));

        if (wkavaBal > 10e12) {
            lastReinvestTs = block.timestamp;

            // performance fee
            if (performanceFeeRatio > 0) {
                uint fee = wkavaBal * performanceFeeRatio / 100;
                IERC20(wkava).safeTransfer(feeReceiver, fee);
                wkavaBal = wkavaBal - fee;
            }

            // sell kava to usdc
            IERC20(wkava).approve(router, wkavaBal);    
            IEquillRouter(router).swapExactTokensForTokensSimple(wkavaBal, 1, wkava, usdc, false, address(this), block.timestamp);

            // reinvest
            uint usdcBal = IERC20(usdc).balanceOf(address(this));
            uint[3] memory amounts;
            amounts[1] = usdcBal;
            IERC20(usdc).approve(crv3pool, usdcBal);
            ICurvePool(crv3pool).add_liquidity(amounts, 1);

            uint crv3poolBal = IERC20(crv3pool).balanceOf(address(this));
            IERC20(crv3pool).approve(crv3poolGauge, crv3poolBal);
            ICurveGauge(crv3poolGauge).deposit(crv3poolBal);
        }

    }



}