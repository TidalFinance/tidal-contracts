// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./NonReentrancy.sol";
import "./WeekManaged.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/ISeller.sol";

// This contract is owned by Timelock.
contract Seller is ISeller, Ownable, WeekManaged, NonReentrancy {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IRegistry public registry;

    struct WithdrawRequest {
        uint256 amount;
        uint256 time;
        bool executed;
    }

    // who => week => category => WithdrawRequest
    mapping(address => mapping(uint256 => mapping(uint8 => WithdrawRequest))) public withdrawRequestMap;

    mapping(address => mapping(uint16 => bool)) public userBasket;

    struct BasketRequest {
        uint16[] assetIndexes;
        uint256 time;
        bool executed;
    }

    // who => week => category => BasketRequest
    mapping(address => mapping(uint256 => mapping(uint8 => BasketRequest))) public basketRequestMap;

    struct PoolInfo {
        uint256 weekOfPremium;
        uint256 weekOfBonus;
        uint256 premiumPerShare;
        uint256 bonusPerShare;
    }

    mapping(uint16 => PoolInfo) public poolInfo;

    struct UserBalance {
        uint256 currentBalance;
        uint256 futureBalance;
    }

    mapping(address => mapping(uint8 => UserBalance)) public userBalance;

    struct UserInfo {
        uint256 week;
        uint256 premium;
        uint256 bonus;
    }

    mapping(address => UserInfo) public userInfo;

    // By category.
    mapping(uint8 => uint256) public categoryBalance;

    // assetIndex => amount
    mapping(uint16 => uint256) public override assetBalance;

    struct PayoutInfo {
        address toAddress;
        uint256 total;
        uint256 unitPerShare;
        uint256 paid;
        bool finished;
    }

    // assetIndex => payoutId => PayoutInfo
    mapping(uint16 => mapping(uint256 => PayoutInfo)) public payoutInfo;

    // assetIndex => payoutId
    mapping(uint16 => uint256) public payoutIdMap;

    // who => assetIndex => payoutId
    mapping(address => mapping(uint16 => uint256)) userPayoutIdMap;

    constructor () public { }

    function setRegistry(IRegistry registry_) external onlyOwner {
        registry = registry_;
    }

    // Update and pay last week's premium.
    function updatePremium(uint16 assetIndex_) external lock {
        uint256 week = getCurrentWeek();
        require(IBuyer(registry.buyer()).weekToUpdate() == week, "buyer not ready");
        require(poolInfo[assetIndex_].weekOfPremium < week, "already updated");

        uint256 amount = IBuyer(registry.buyer()).premiumForSeller(assetIndex_);

        if (assetBalance[assetIndex_] > 0) {
            IERC20(registry.baseToken()).safeTransferFrom(registry.buyer(), address(this), amount);
            poolInfo[assetIndex_].premiumPerShare =
                amount.mul(registry.UNIT_PER_SHARE()).div(assetBalance[assetIndex_]);
        }

        poolInfo[assetIndex_].weekOfPremium = week;
    }

    // Update and pay last week's bonus.
    function updateBonus(uint16 assetIndex_, uint256 amount_) external lock override {
        require(msg.sender == registry.bonus(), "Only Bonus can call");

        uint256 week = getCurrentWeek();

        require(poolInfo[assetIndex_].weekOfBonus < week, "already updated");

        if (assetBalance[assetIndex_] > 0) {
            IERC20(registry.tidalToken()).safeTransferFrom(msg.sender, address(this), amount_);
            poolInfo[assetIndex_].bonusPerShare =
                amount_.mul(registry.UNIT_PER_SHARE()).div(assetBalance[assetIndex_]);
        }

        poolInfo[assetIndex_].weekOfBonus = week;
    }

    function isAssetLocked(address who_, uint8 category_) public view returns(bool) {
        for (uint256 i = 0; i < IAssetManager(registry.assetManager()).getIndexesByCategoryLength(category_); ++i) {
            uint16 index = IAssetManager(registry.assetManager()).getIndexesByCategory(category_, i);
            uint256 payoutId = payoutIdMap[index];

            if (payoutId > 0 && !payoutInfo[index][payoutId].finished &&
                userBasket[who_][index] && userPayoutIdMap[who_][index] < payoutId) return true;
        }

        return false;
    }

    function hasPendingPayout(uint16[] memory basketIndexes_) public view returns(bool) {
        for (uint256 i = 0; i < basketIndexes_.length; ++i) {
            uint16 assetIndex = basketIndexes_[i];
            uint256 payoutId = payoutIdMap[assetIndex];
            if (payoutId > 0 && !payoutInfo[assetIndex][payoutId].finished) return true;
        }

        return false;
    }

    function hasIndex(uint16[] memory basketIndexes_, uint16 index_) public pure returns(bool) {
        for (uint256 i = 0; i < basketIndexes_.length; ++i) {
            if (basketIndexes_[i] == index_) return true;
        }

        return false;
    }

    function changeBasket(uint8 category_, uint16[] calldata basketIndexes_) external {
        require(!isAssetLocked(msg.sender, category_), "Asset locked");
        require(userInfo[msg.sender].week == getCurrentWeek(), "Not updated yet");
        require(!hasPendingPayout(basketIndexes_), "Has pending payout");

        if (userBalance[msg.sender][category_].currentBalance == 0) {
            // Change now.

            for (uint256 i = 0;
                    i < IAssetManager(registry.assetManager()).getIndexesByCategoryLength(category_);
                    ++i) {
                uint16 index = uint16(IAssetManager(registry.assetManager()).getIndexesByCategory(category_, i));
                bool has = hasIndex(basketIndexes_, index);

                if (has && !userBasket[msg.sender][index]) {
                    userBasket[msg.sender][index] = true;
                } else if (!has && userBasket[msg.sender][index]) {
                    userBasket[msg.sender][index] = false;
                }
            }
        } else {
            // Change later.

            BasketRequest memory request;
            request.assetIndexes = basketIndexes_;
            request.time = getNow();
            request.executed = false;

            // One request per week per category.
            basketRequestMap[msg.sender][getUnlockWeek()][category_] = request;
        }
    }

    function changeBasketReady(address who_, uint8 category_) external {
        BasketRequest storage request = basketRequestMap[who_][getCurrentWeek()][category_];

        require(!isAssetLocked(who_, category_), "Asset locked");
        require(userInfo[who_].week == getCurrentWeek(), "Not updated yet");
        require(!request.executed, "already executed");
        require(request.time > 0, "No request");

        uint256 unlockTime = getUnlockTime(request.time);
        require(getNow() > unlockTime, "Not ready to change yet");

        uint256 currentBalance = userBalance[who_][category_].currentBalance;

        for (uint256 i = 0;
                i < IAssetManager(registry.assetManager()).getIndexesByCategoryLength(category_);
                ++i) {
            uint16 index = uint16(IAssetManager(registry.assetManager()).getIndexesByCategory(category_, i));
            bool has = hasIndex(request.assetIndexes, index);

            if (has && !userBasket[msg.sender][index]) {
                userBasket[msg.sender][index] = true;
                assetBalance[index] = assetBalance[index].add(
                    currentBalance);
            } else if (!has && userBasket[msg.sender][index]) {
                userBasket[msg.sender][index] = false;
                assetBalance[index] = assetBalance[index].sub(
                    currentBalance);
            }
        }

        request.executed = true;
    }

    // Called for every user every week.
    function update(address who_) external {
        // Update user's last week's premium and bonus.
        uint256 week = getCurrentWeek();

        require(userInfo[who_].week < week, "Already updated");

        uint16 index;
        // Assert if premium or bonus not updated, or user already updated.
        for (index = 0;
                index < IAssetManager(registry.assetManager()).getAssetLength();
                ++index) {
            require(poolInfo[index].weekOfPremium == week &&
                poolInfo[index].weekOfBonus == week, "Not ready");
        }

        uint8 category;

        // For every asset
        for (index = 0;
                index < IAssetManager(registry.assetManager()).getAssetLength();
                ++index) {
            category = IAssetManager(registry.assetManager()).getAssetCategory(index);
            uint256 currentBalance = userBalance[who_][category].currentBalance;
            uint256 futureBalance = userBalance[who_][category].futureBalance;

            // Update premium.
            userInfo[who_].premium = userInfo[who_].premium.add(currentBalance.mul(
                poolInfo[index].premiumPerShare).div(registry.UNIT_PER_SHARE()));

            // Update bonus.
            userInfo[who_].bonus = userInfo[who_].bonus.add(currentBalance.mul(
                poolInfo[index].bonusPerShare).div(registry.UNIT_PER_SHARE()));

            // Update asset balance if no claims.
            if (!isAssetLocked(who_, category) && userBasket[who_][index]) {
                assetBalance[index] = assetBalance[index].add(futureBalance).sub(currentBalance);
            }
        }

        // Update user balance and category balance if no claims.
        for (category = 0;
                category < IAssetManager(registry.assetManager()).getCategoryLength();
                ++category) {
            if (!isAssetLocked(who_, category)) {
                uint256 currentBalance = userBalance[who_][category].currentBalance;
                uint256 futureBalance = userBalance[who_][category].futureBalance;

                userBalance[who_][category].currentBalance = futureBalance;
                categoryBalance[category] = categoryBalance[category].add(
                    futureBalance).sub(currentBalance);
            }
        }

        // Update week.
        userInfo[who_].week = week;
    }

    function deposit(uint8 category_, uint256 amount_) external lock {
        require(!isAssetLocked(msg.sender, category_), "Asset locked");
        require(userInfo[msg.sender].week == getCurrentWeek(), "Not updated yet");

        IERC20(registry.baseToken()).safeTransferFrom(msg.sender, address(this), amount_);

        userBalance[msg.sender][category_].futureBalance = userBalance[msg.sender][category_].futureBalance.add(amount_);
    }

    function reduceDeposit(uint8 category_, uint256 amount_) external lock {
        // Even asset locked, user can still reduce.

        require(userInfo[msg.sender].week == getCurrentWeek(), "Not updated yet");
        require(userBalance[msg.sender][category_].futureBalance >= amount_, "Not enough future balance");

        IERC20(registry.baseToken()).safeTransfer(msg.sender, amount_);

        userBalance[msg.sender][category_].futureBalance = userBalance[msg.sender][category_].futureBalance.sub(amount_);
    }

    function withdraw(uint8 category_, uint256 amount_) external {
        require(!isAssetLocked(msg.sender, category_), "Asset locked");
        require(userInfo[msg.sender].week == getCurrentWeek(), "Not updated yet");

        require(amount_ > 0, "Requires positive amount");
        require(amount_ <= userBalance[msg.sender][category_].currentBalance, "Not enough user balance");

        WithdrawRequest memory request;
        request.amount = amount_;
        request.time = getNow();
        request.executed = false;
        withdrawRequestMap[msg.sender][getUnlockWeek()][category_] = request;
    }

    function withdrawReady(address who_, uint8 category_) external lock {
        WithdrawRequest storage request = withdrawRequestMap[who_][getCurrentWeek()][category_];

        require(!isAssetLocked(who_, category_), "Asset locked");
        require(userInfo[who_].week == getCurrentWeek(), "Not updated yet");
        require(!request.executed, "already executed");
        require(request.time > 0, "No request");

        uint256 unlockTime = getUnlockTime(request.time);
        require(getNow() > unlockTime, "Not ready to withdraw yet");

        IERC20(registry.baseToken()).safeTransfer(who_, request.amount);

        for (uint256 i = 0;
                i < IAssetManager(registry.assetManager()).getIndexesByCategoryLength(category_);
                ++i) {
            uint16 index = IAssetManager(registry.assetManager()).getIndexesByCategory(category_, i);

            // Only process assets in my basket.
            if (userBasket[who_][index]) {
                assetBalance[index] = assetBalance[index].sub(request.amount);
            }
        }

        userBalance[who_][category_].currentBalance = userBalance[who_][category_].currentBalance.sub(request.amount);
        userBalance[who_][category_].futureBalance = userBalance[who_][category_].futureBalance.sub(request.amount);
        categoryBalance[category_] = categoryBalance[category_].sub(request.amount);
 
        request.executed = true;
    }

    function claimPremium() external lock {
        IERC20(registry.baseToken()).safeTransfer(msg.sender, userInfo[msg.sender].premium);
        userInfo[msg.sender].premium = 0;
    }

    function claimBonus() external lock {
        IERC20(registry.tidalToken()).safeTransfer(msg.sender, userInfo[msg.sender].bonus);
        userInfo[msg.sender].bonus = 0;
    }

    function startPayout(uint16 assetIndex_, uint256 payoutId_) external override {
        require(msg.sender == registry.committee(), "Only commitee can call");

        require(payoutId_ == payoutIdMap[assetIndex_] + 1, "payoutId should be increasing");
        payoutIdMap[assetIndex_] = payoutId_;
    }

    function setPayout(uint16 assetIndex_, uint256 payoutId_, address toAddress_, uint256 total_) external override {
        require(msg.sender == registry.committee(), "Only commitee can call");

        require(payoutId_ == payoutIdMap[assetIndex_], "payoutId should be started");
        require(payoutInfo[assetIndex_][payoutId_].toAddress == address(0), "already set");
        require(total_ <= assetBalance[assetIndex_], "More than asset");

        // total_ can be 0.

        payoutInfo[assetIndex_][payoutId_].toAddress = toAddress_;
        payoutInfo[assetIndex_][payoutId_].total = total_;
        payoutInfo[assetIndex_][payoutId_].unitPerShare = total_.mul(registry.UNIT_PER_SHARE()).div(assetBalance[assetIndex_]);
        payoutInfo[assetIndex_][payoutId_].paid = 0;
        payoutInfo[assetIndex_][payoutId_].finished = false;
    }

    // This function can be called by anyone.
    function doPayout(address who_, uint16 assetIndex_) external {
        require(userBasket[who_][assetIndex_], "must be in basket");

        uint256 payoutId = payoutIdMap[assetIndex_];

        require(payoutInfo[assetIndex_][payoutId].toAddress != address(0), "not set");

        userPayoutIdMap[who_][assetIndex_] = payoutId;

        if (payoutInfo[assetIndex_][payoutId].finished) {
            // In case someone paid for the difference.
            return;
        }

        uint8 category = IAssetManager(registry.assetManager()).getAssetCategory(assetIndex_);
        uint256 amountToPay = userBalance[who_][category].currentBalance.mul(
            payoutInfo[assetIndex_][payoutId].unitPerShare).div(registry.UNIT_PER_SHARE());

        userBalance[who_][category].currentBalance = userBalance[who_][category].currentBalance.sub(amountToPay);
        userBalance[who_][category].futureBalance = userBalance[who_][category].futureBalance.sub(amountToPay);
        categoryBalance[category] = categoryBalance[category].sub(amountToPay);
        assetBalance[assetIndex_] = assetBalance[assetIndex_].sub(amountToPay);

        payoutInfo[assetIndex_][payoutId].paid = payoutInfo[assetIndex_][payoutId].paid.add(amountToPay);
    }

    // This function can be called by anyone as long as he will pay for the difference.
    function finishPayout(uint16 assetIndex_, uint256 payoutId_) external lock {
        require(payoutId_ <= payoutIdMap[assetIndex_], "payoutId should be valid");
        require(!payoutInfo[assetIndex_][payoutId_].finished, "already finished");

        if (payoutInfo[assetIndex_][payoutId_].paid < payoutInfo[assetIndex_][payoutId_].total) {
            // In case you wanna pay for the difference.
            IERC20(registry.baseToken()).safeTransferFrom(
                msg.sender,
                address(this),
                payoutInfo[assetIndex_][payoutId_].total.sub(payoutInfo[assetIndex_][payoutId_].paid));
            payoutInfo[assetIndex_][payoutId_].paid = payoutInfo[assetIndex_][payoutId_].total;
        }

        IERC20(registry.baseToken()).safeTransfer(payoutInfo[assetIndex_][payoutId_].toAddress,
                                                  payoutInfo[assetIndex_][payoutId_].total);

        payoutInfo[assetIndex_][payoutId_].finished = true;
    }

    function getPendingBasket(address who_, uint8 category_, uint256 week_) external view returns(uint16[] memory) {
        BasketRequest storage request = basketRequestMap[who_][week_][category_];
        return request.assetIndexes;
    }
}
