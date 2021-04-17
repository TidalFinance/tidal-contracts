// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IGuarantor {
    function updateBonus(uint16 assetIndex_, uint256 amount_) external;
}
