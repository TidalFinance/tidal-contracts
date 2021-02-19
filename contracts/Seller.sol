// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Seller is ISeller, Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // The computing ability of EVM is limited, so we cap the maximum number of iterations
    // at 100. If the gap is larger, just compute multiple times.
    uint256 constant MAXIMUM_ITERATION = 100;

    IBuyer public buyer;
    IAssetManager public assetManager;

    constructor (IBuyer buyer_, IAssetManager assetManager_) public {
        buyer = buyer_;
        assetManager = assetManager_;
    }

    function sellAsGuarantor() external {
    }

    function sellAsUser() external {
    }

    function distributeBonus() external {
    }
}
