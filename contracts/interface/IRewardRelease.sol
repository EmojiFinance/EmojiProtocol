pragma solidity ^0.8.0;

interface IRewardRelease {
    function release(address user, uint amount) external;
}