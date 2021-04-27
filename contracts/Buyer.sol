// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./NonReentrancy.sol";
import "./PremiumCalculator.sol";
import "./WeekManaged.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Buyer is IBuyer, Ownable, WeekManaged, NonReentrancy {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IRegistry public registry;

    struct PoolInfo {
        uint256 weekOfBonus;
        uint256 bonusPerShare;
    }

    // assetIndex => PoolInfo
    mapping(uint16 => PoolInfo) public poolInfo;

    struct UserInfo {
        uint256 balance;
        uint256 weekBegin;  // The week the coverage begin
        uint256 weekEnd;  // The week the coverage end
        uint256 weekUpdated;  // The week that balance was updated
        uint256 bonus;
    }

    mapping(address => UserInfo) public userInfoMap;

    // user => assetIndex => amount
    mapping(address => mapping(uint16 => uint256)) public override currentSubscription;

    // user => assetIndex => amount
    mapping(address => mapping(uint16 => uint256)) public override futureSubscription;

    // assetIndex => total
    mapping(uint16 => uint256) public assetSubscription;

    // assetIndex => utilization
    mapping(uint16 => uint256) public assetUtilization;

    // assetIndex => total
    mapping(uint16 => uint256) public override premiumForGuarantor;

    // assetIndex => total
    mapping(uint16 => uint256) public override premiumForSeller;

    uint256 public override weekToUpdate;

    constructor () public { }

    function setRegistry(IRegistry registry_) external onlyOwner {
        registry = registry_;
    }

    function getPremiumRate(uint16 assetIndex_) public view returns(uint256) {
        uint8 category = IAssetManager(registry.assetManager()).getAssetCategory(assetIndex_);
        return PremiumCalculator(registry.premiumCalculator()).getPremiumRate(
            category, assetUtilization[assetIndex_]);
    }

    function isUserCovered(address who_) public override view returns(bool) {
        return userInfoMap[who_].weekEnd == getCurrentWeek();
    }

    function getTotalFuturePremium(address who_) public view returns(uint256) {
        uint256 total = 0;
        for (uint16 index = 0; index < IAssetManager(registry.assetManager()).getAssetLength(); ++index) {
            if (futureSubscription[who_][index] > 0) {
                total = total.add(futureSubscription[who_][index].mul(getPremiumRate(index)).div(registry.PREMIUM_BASE()));
            }
        }

        return total;
    }

    function getBalance(address who_) public view returns(uint256) {
        return userInfoMap[who_].balance;
    }

    function getUtilization(uint16 assetIndex_) public view returns(uint256) {
        uint256 sellerAssetBalance = ISeller(registry.seller()).assetBalance(assetIndex_);

        if (sellerAssetBalance == 0) {
            return 0;
        }

        if (assetSubscription[assetIndex_] > sellerAssetBalance) {
            return registry.UTILIZATION_BASE();
        }

        return assetSubscription[assetIndex_] * registry.UTILIZATION_BASE() / sellerAssetBalance;
    }

    // Called every week.
    function beforeUpdate() external lock {
        uint256 currentWeek = getCurrentWeek();

        require(weekToUpdate < currentWeek, "Already called");

        if (weekToUpdate > 0) {
            uint256 totalForGuarantor = 0;
            uint256 totalForSeller = 0;
            uint256 feeForPlatform = 0;

            // To preserve last week's data before update buyers.
            for (uint16 index = 0;
                    index < IAssetManager(registry.assetManager()).getAssetLength();
                    ++index) {
                uint256 premiumOfAsset = assetSubscription[index].mul(
                    getPremiumRate(index)).div(registry.PREMIUM_BASE());

                premiumForGuarantor[index] = premiumOfAsset.mul(
                    registry.guarantorPercentage()).div(registry.PERCENTAGE_BASE());
                totalForGuarantor = totalForGuarantor.add(premiumForGuarantor[index]);

                feeForPlatform = feeForPlatform.add(
                    premiumOfAsset.mul(registry.platformPercentage()).div(registry.PERCENTAGE_BASE()));

                premiumForSeller[index] = premiumOfAsset.mul(
                    registry.PERCENTAGE_BASE().sub(registry.guarantorPercentage()).sub(
                        registry.platformPercentage())).div(registry.PERCENTAGE_BASE());
                totalForSeller = totalForSeller.add(premiumForSeller[index]);

                // Calculate assetUtilization from assetSubscription and seller.assetBalance
                assetUtilization[index] = getUtilization(index);
            }

            IERC20(registry.baseToken()).safeTransfer(registry.platform(), feeForPlatform);
            IERC20(registry.baseToken()).safeApprove(registry.guarantor(), totalForGuarantor);
            IERC20(registry.baseToken()).safeApprove(registry.seller(), totalForSeller);
        }

        weekToUpdate = currentWeek;
    }

    // Update and pay last week's bonus.
    function updateBonus(uint16 assetIndex_, uint256 amount_) external lock override {
        require(msg.sender == registry.bonus(), "Only Bonus can call");

        uint256 currentWeek = getCurrentWeek();

        require(currentWeek == weekToUpdate, "Not ready to update");
        require(poolInfo[assetIndex_].weekOfBonus < currentWeek, "already updated");

        if (assetSubscription[assetIndex_] > 0) {
            IERC20(registry.tidalToken()).safeTransferFrom(msg.sender, address(this), amount_);
            poolInfo[assetIndex_].bonusPerShare = amount_.mul(
                registry.UNIT_PER_SHARE()).div(assetSubscription[assetIndex_]);
        }

        poolInfo[assetIndex_].weekOfBonus = currentWeek;

        // HACK: Now reset, because it's useless and we will re-sum it later.
        assetSubscription[assetIndex_] = 0;
    }

    // Called for every user every week.
    function update(address who_) public {
        uint256 currentWeek = getCurrentWeek();

        require(currentWeek == weekToUpdate, "Not ready to update");
        require(userInfoMap[who_].weekUpdated < currentWeek, "Already updated");

        uint16 index;

        // Check bonus.
        for (index = 0; index < IAssetManager(registry.assetManager()).getAssetLength(); ++index) {
            require(poolInfo[index].weekOfBonus == currentWeek, "Not ready");
        }

        // Get per user premium
        uint256 cost = getTotalFuturePremium(who_);

        if (userInfoMap[who_].balance >= cost) {
            userInfoMap[who_].balance = userInfoMap[who_].balance.sub(cost);

            if (userInfoMap[who_].weekBegin == 0 ||
                    userInfoMap[who_].weekEnd < userInfoMap[who_].weekUpdated) {
                userInfoMap[who_].weekBegin = currentWeek;
            }

            userInfoMap[who_].weekEnd = currentWeek;

            for (index = 0; index < IAssetManager(registry.assetManager()).getAssetLength(); ++index) {
                // Update user bonus.
                userInfoMap[who_].bonus = userInfoMap[who_].bonus.add(currentSubscription[who_][index].mul(
                    poolInfo[index].bonusPerShare).div(registry.UNIT_PER_SHARE()));

                if (futureSubscription[who_][index] > 0) {
                    currentSubscription[who_][index] = futureSubscription[who_][index];

                    // Update per asset premium
                    assetSubscription[index] = assetSubscription[index].add(
                            futureSubscription[who_][index]);
                } else if (currentSubscription[who_][index] > 0) {
                    currentSubscription[who_][index] = 0;
                }
            }
        }

        userInfoMap[who_].weekUpdated = currentWeek;  // This week.
    }

    // Deposit
    function deposit(uint256 amount_) external lock {
        IERC20(registry.baseToken()).safeTransferFrom(msg.sender, address(this), amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.add(amount_);
    }

    // Withdraw
    function withdraw(uint256 amount_) external lock {
        require(userInfoMap[msg.sender].balance > amount_, "not enough balance");
        IERC20(registry.baseToken()).safeTransfer(msg.sender, amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.sub(amount_);
    }

    function subscribe(uint16 assetIndex_, uint256 amount_) external {
        futureSubscription[msg.sender][assetIndex_] = futureSubscription[msg.sender][assetIndex_].add(amount_);
    }

    function unsubscribe(uint16 assetIndex_, uint256 amount_) external {
        futureSubscription[msg.sender][assetIndex_] = futureSubscription[msg.sender][assetIndex_].sub(amount_);
    }

    function claimBonus() external lock {
        IERC20(registry.tidalToken()).safeTransfer(msg.sender, userInfoMap[msg.sender].bonus);
        userInfoMap[msg.sender].bonus = 0;
    }
}
