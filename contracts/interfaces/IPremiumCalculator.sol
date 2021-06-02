// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IPremiumCalculator {
    function getPremiumRate(uint16 assetIndex_) external view returns(uint256);
}
