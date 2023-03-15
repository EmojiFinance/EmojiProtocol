pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interface/IEquillRouter.sol";
import "./interface/IRewardRelease.sol";

contract EquiliLpVault {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount; 
        uint256 rewardDebt; 
        uint256 pending;
    }

    address public immutable lp;
    address public immutable gauge;
    address public immutable token0;
    address public immutable token1;
    bool public immutable stable;

    address public immutable wkava = 0xc86c7C0eFbd6A49B35E8714C5f59D99De09A225b;
    address public immutable usdc = 0xfA9343C3897324496A05fC75abeD6bAC29f8A40f;
    address public immutable dai = 0x765277EebeCA2e31912C9946eAe1021199B39C61;
    address public immutable vara = 0xE1da44C0dA55B075aE8E2e4b6986AdC76Ac77d73;
    address public immutable eth = 0xE3F5a90F9cb311505cd691a46596599aA1A0AD7D;
    address public immutable wbtc = 0x818ec0A7Fe18Ff94269904fCED6AE3DaE6d6dC0b;
    
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


    struct ReinvestInfo {
        uint dust;
        IEquillRouter.route[] path0;
        IEquillRouter.route[] path1;
    }

    address[] public claimTokens;
    mapping(address => ReinvestInfo) public paths;

    constructor (
        address _feeReceiver,
        address _rewarder,
        address _lp,
        address _gauge
    ) {      
        operator = msg.sender;
        feeReceiver = _feeReceiver;
        rewarder = _rewarder;
        lp = _lp;
        gauge = _gauge;
        token0 = IEquiliPair(lp).token0();
        token1 = IEquiliPair(lp).token1();
        stable = IEquiliPair(lp).stable();
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

    function setClaimTokens(
        address[] memory _claimTokens
    ) public onlyOperator {
        claimTokens = _claimTokens;
    }

    function setPaths(
        address[] memory tokens,
        ReinvestInfo[] memory infos
    ) public onlyOperator {
        _setPaths(tokens, infos);
    }

    function _setPaths(
        address[] memory tokens,
        ReinvestInfo[] memory infos
    ) internal {
        claimTokens = tokens;
        for (uint j = 0; j < tokens.length; j++) {
            ReinvestInfo storage info = paths[tokens[j]];
            
            delete info.path0;
            delete info.path1;
            
            ReinvestInfo memory tmp = infos[j];
            info.dust = tmp.dust;
            for (uint i = 0; i < tmp.path0.length; i++) {
                info.path0.push(tmp.path0[i]);
            }
            for (uint i = 0; i < tmp.path1.length; i++) {
                info.path1.push(tmp.path1[i]);
            }
        }
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
        uint beforeBal = IEquiliGauge(gauge).balanceOf(address(this));
        
        if (totalShareAmount == 0) {
            shareAmount = amount;
        } else {
            shareAmount = amount * totalShareAmount / beforeBal;
        }

        IERC20(lp).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(lp).approve(gauge, 0);
        IERC20(lp).approve(gauge, amount);
        IEquiliGauge(gauge).deposit(amount, 0);

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
        uint beforeBal = IEquiliGauge(gauge).balanceOf(address(this));
        

        shareAmount = amount * totalShareAmount / beforeBal;
        require(shareAmount <= user.amount);

        IEquiliGauge(gauge).withdraw(amount);
        if (lastDepositTs[msg.sender] > block.timestamp - withdrawFreePeriod) {
            uint fee = amount * withdrawFeeRatio / 1000;
            IERC20(lp).safeTransfer(feeReceiver, fee);
            IERC20(lp).safeTransfer(msg.sender, amount - fee);
        } else {
            IERC20(lp).safeTransfer(msg.sender, amount);
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

        uint beforeBal = IEquiliGauge(gauge).balanceOf(address(this));
        uint amount = shareAmount * beforeBal / totalShareAmount;

        IEquiliGauge(gauge).withdraw(amount);
        if (lastDepositTs[msg.sender] > block.timestamp - withdrawFreePeriod) {
            uint fee = amount * withdrawFeeRatio / 1000;
            IERC20(lp).safeTransfer(feeReceiver, fee);
            IERC20(lp).safeTransfer(msg.sender, amount - fee);
        } else {
            IERC20(lp).safeTransfer(msg.sender, amount);
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
        uint beforeBal = IERC20(gauge).balanceOf(address(this));
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
        if (totalShareAmount == 0) {
            return;
        }
        lastReinvestTs = block.timestamp;

        IEquiliGauge(gauge).getReward(address(this), claimTokens);

        for(uint i = 0; i < claimTokens.length; i++) {
            address token = claimTokens[i];
            uint bal = IERC20(token).balanceOf(address(this));
            ReinvestInfo memory path = paths[token];
            if (bal > path.dust) {
                IERC20(token).approve(router, 0);
                IERC20(token).approve(router, bal);
                if (path.path0.length > 0) {
                    IEquillRouter(router).swapExactTokensForTokens(bal / 2, 1, path.path0, address(this), block.timestamp);
                }
                if (path.path1.length > 0) {
                    IEquillRouter(router).swapExactTokensForTokens(bal / 2, 1, path.path1, address(this), block.timestamp);
                }
            }
        }

        uint token0Bal = IERC20(token0).balanceOf(address(this));
        uint token1Bal = IERC20(token1).balanceOf(address(this));
        if (token0Bal > 0 && token1Bal > 0) {
            IERC20(token0).approve(router, 0);
            IERC20(token1).approve(router, 0);
            IERC20(token0).approve(router, token0Bal);
            IERC20(token1).approve(router, token1Bal);
            IEquillRouter(router).addLiquidity(token0, token1, stable, token0Bal, token1Bal, 1, 1, address(this), block.timestamp);
        }

        uint lpBal = IERC20(lp).balanceOf(address(this));
        if (lpBal > 0) {
            IERC20(lp).approve(gauge, 0);
            IERC20(lp).approve(gauge, lpBal);
            IEquiliGauge(gauge).deposit(lpBal, 0);
        }
    }

}