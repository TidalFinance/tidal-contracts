// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IRegistry.sol";

contract Registry is Ownable, IRegistry {

    // The base of percentage.
    uint256 public override constant PERCENTAGE_BASE = 100;

    // The base of utilization.
    uint256 public override constant UTILIZATION_BASE = 1e6;

    // The base of premium rate and accWeeklyCost
    uint256 public override constant PREMIUM_BASE = 1e6;

    // For improving precision of bonusPerShare.
    uint256 public override constant UNIT_PER_SHARE = 1e18;

    address public override buyer;
    address public override seller;
    address public override guarantor;
    address public override bonus;
    address public override premiumManager;

    address public override tidalToken;
    address public override baseToken;
    address public override assetManager;
    address public override premiumCalculator;
    address public override platform;

    uint256 public override guarantorPercentage = 5;  // 5%
    uint256 public override platformPercentage = 5;  // 5%

    function setBuyer(address buyer_) external onlyOwner {
        buyer = buyer_;
    }

    function setSeller(address seller_) external onlyOwner {
        seller = seller_;
    }

    function setGuarantor(address guarantor_) external onlyOwner {
        guarantor = guarantor_;
    }

    function setBonus(address bonus_) external onlyOwner {
        bonus = bonus_;
    }

    function setTidalToken(address tidalToken_) external onlyOwner {
        tidalToken = tidalToken_;
    }

    function setBaseToken(address baseToken_) external onlyOwner {
        baseToken = baseToken_;
    }

    function setAssetManager(address assetManager_) external onlyOwner {
        assetManager = assetManager_;
    }

    function setPremiumManager(address premiumManager_) external onlyOwner {
        premiumManager = premiumManager_;
    }

    function setPlatform(address platform_) external onlyOwner {
        platform = platform_;
    }

    function setGuarantorPercentage(uint256 percentage_) external onlyOwner {
        require(percentage_ < PERCENTAGE_BASE, "Invalid input");
        guarantorPercentage = percentage_;
    }

    function setPlatformPercentage(uint256 percentage_) external onlyOwner {
        require(percentage_ < PERCENTAGE_BASE, "Invalid input");
        platformPercentage = percentage_;
    }
}
