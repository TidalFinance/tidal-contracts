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

    // For debug purpose.
    uint256 public override timeExtra = 0;

    address public override buyer;
    address public override seller;
    address public override guarantor;
    address public override staking;
    address public override bonus;

    address public override tidalToken;
    address public override baseToken;
    address public override assetManager;
    address public override premiumCalculator;
    address public override platform;  // Fees go here.

    uint256 public override guarantorPercentage = 5;  // 5%
    uint256 public override platformPercentage = 5;  // 5%

    uint256 public override stakingWithdrawWaitTime = 14 days;

    address public override governor;
    address public override committee;

    address public override trustedForwarder;

    // This function will be removed in production.
    function setTimeExtra(uint256 timeExtra_) external onlyOwner {
        timeExtra = timeExtra_;
    }

    function setBuyer(address buyer_) external onlyOwner {
        require(buyer == address(0), "Can set only once");
        buyer = buyer_;
    }

    function setSeller(address seller_) external onlyOwner {
        require(seller == address(0), "Can set only once");
        seller = seller_;
    }

    function setGuarantor(address guarantor_) external onlyOwner {
        require(guarantor == address(0), "Can set only once");
        guarantor = guarantor_;
    }

    // Upgradable, in case we want to change staking pool.
    function setStaking(address staking_) external onlyOwner {
        staking = staking_;
    }

    // Upgradable, in case we want to change mining algorithm.
    function setBonus(address bonus_) external onlyOwner {
        bonus = bonus_;
    }

    function setTidalToken(address tidalToken_) external onlyOwner {
        require(tidalToken == address(0), "Can set only once");
        tidalToken = tidalToken_;
    }

    function setBaseToken(address baseToken_) external onlyOwner {
        require(baseToken == address(0), "Can set only once");
        baseToken = baseToken_;
    }

    function setAssetManager(address assetManager_) external onlyOwner {
        require(assetManager == address(0), "Can set only once");
        assetManager = assetManager_;
    }

    // Upgradable, in case we want to change premium formula.
    function setPremiumCalculator(address premiumCalculator_) external onlyOwner {
        premiumCalculator = premiumCalculator_;
    }

    // Upgradable.
    function setPlatform(address platform_) external onlyOwner {
        platform = platform_;
    }

    // Upgradable.
    function setGuarantorPercentage(uint256 percentage_) external onlyOwner {
        require(percentage_ < PERCENTAGE_BASE, "Invalid input");
        guarantorPercentage = percentage_;
    }

    // Upgradable.
    function setPlatformPercentage(uint256 percentage_) external onlyOwner {
        require(percentage_ < PERCENTAGE_BASE, "Invalid input");
        platformPercentage = percentage_;
    }

    // Upgradable.
    function setStakingWithdrawWaitTime(uint256 stakingWithdrawWaitTime_) external onlyOwner {
        stakingWithdrawWaitTime = stakingWithdrawWaitTime_;
    }

    // Upgradable.
    function setGovernor(address governor_) external onlyOwner {
        governor = governor_;
    }

    // Upgradable.
    function setCommittee(address committee_) external onlyOwner {
        committee = committee_;
    }

    // Upgradable.
    function setTrustedForwarder(address trustedForwarder_) external onlyOwner {
        trustedForwarder = trustedForwarder_;
    }
}
