pragma solidity ^0.8.0;


interface ICurvePool {
    function add_liquidity(uint[3] memory amounts, uint min_ret_amount) external returns (uint);
}

interface ICurveGauge {
    function balanceOf(address account) external view returns (uint256);
    function claimable_reward(address _addr, address _token) external view returns (uint256);
    function claim_rewards(address _addr) external;
    function deposit(uint256 _value) external;
    function withdraw(uint256 _value) external;
    function reward_contract() external view returns (address);
}