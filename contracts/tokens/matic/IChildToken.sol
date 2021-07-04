pragma solidity 0.6.12;

interface IChildToken {
    function deposit(address user, bytes calldata depositData) external;
}
