// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IPolicy {
    function accWeeklyCost(uint256 week_) external view returns(uint256);
}
