// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../common/BaseRelayRecipient.sol";
import "../common/NonReentrancy.sol";

import "../interfaces/IAssetManager.sol";
import "../interfaces/IRegistry.sol";
import "../interfaces/ISeller.sol";

interface IRetailPremiumCalculator {
    function getPremiumRate(uint16 assetIndex_, address who_) external view returns(uint256);
}

contract RetailHelper is Ownable, NonReentrancy, BaseRelayRecipient {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    string public override versionRecipient = "1.0.0";

    uint256 public constant PRICE_BASE = 1e18;
    uint256 public constant REFUND_BASE = 1e18;

    IRegistry public registry;
    IRetailPremiumCalculator public retailPremiumCalculator;

    mapping(address => bool) public updaterMap;

    modifier onlyUpdater() {
        require(updaterMap[msg.sender], "The caller does not have updater role privileges");
        _;
    }

    struct UserInfo {
        uint256 balanceBase;
        uint256 balanceAsset;
        uint256 premiumBase;
        uint256 premiumAsset;

        uint256 weekUpdated;  // The week that UserInfo was updated
    }

    mapping(uint16 => mapping(address => UserInfo)) public userInfoMap;

    struct AssetInfo {
        // The token address here is supposed to be the same as the token adress
        // in assetManager. However we don't use the one in assetManager because
        // sometimes we don't want to setup guarantor for certain assets but do
        // allow them to use ResellHelper.
        address token;
        address recipient;

        uint256 futureCapacityOffset;
        uint256 futureTokenPrice;
        uint256 capacityOffset;
        uint256 tokenPrice;

        uint256 subscriptionBase;
        uint256 subscriptionAsset;  // subscriptionAsset * tokenPrice / PRICE_BASE
        uint256 refundRatio;

        uint256 weekUpdated;  // The week that AssetInfo was updated
    }

    mapping(uint16 => AssetInfo) public assetInfoMap;

    struct Subscription {
        uint256 currentBase;
        uint256 futureBase;
        uint256 currentAsset;
        uint256 futureAsset;
    }

    mapping(uint16 => Subscription) public subscriptionByAsset;
    mapping(uint16 => mapping(address => Subscription)) public subscriptionByUser;

    event DepositBase(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event DepositAsset(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event RefundBase(address indexed who_, uint16 indexed assetIndex_, uint256 premiumAmount_);
    event RefundAsset(address indexed who_, uint16 indexed assetIndex_, uint256 premiumAmount_);
    event DeductBase(address indexed who_, uint16 indexed assetIndex_, uint256 coveredAmount_, uint256 premiumAmount_);
    event DeductAsset(address indexed who_, uint16 indexed assetIndex_, uint256 coveredAmount_, uint256 premiumAmount_);
    event WithdrawBase(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event WithdrawAsset(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event SubscribeBase(address indexed who_, uint16 indexed assetIndex_, uint256 amoun_);
    event SubscribeAsset(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event UnsubscribeBase(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);
    event UnsubscribeAsset(address indexed who_, uint16 indexed assetIndex_, uint256 amount_);

    constructor (IRegistry registry_) public {
        registry = registry_;
    }

    function _msgSender() internal override(Context, BaseRelayRecipient) view returns (address payable) {
        return BaseRelayRecipient._msgSender();
    }

    function _trustedForwarder() internal override view returns(address) {
        return registry.trustedForwarder();
    }

    function setUpdater(address _who, bool _isUpdater) external onlyOwner {
        updaterMap[_who] = _isUpdater;
    }

    function setRetailPremiumCalculator(IRetailPremiumCalculator retailPremiumCalculator_) external onlyOwner {
        retailPremiumCalculator = retailPremiumCalculator_;
    }

    function setAssetInfo(
        uint16 assetIndex_,
        address token_,
        address recipient_,
        uint256 capacityOffset_
    ) external onlyOwner {
        require(recipient_ != address(0), "recipient_ is zero");
        // token_ can be zero, and capacityOffset_ can be zero too.

        assetInfoMap[assetIndex_].token = token_;
        assetInfoMap[assetIndex_].recipient = recipient_;
        assetInfoMap[assetIndex_].capacityOffset = capacityOffset_;
    }

    function changeCapacityOffset(
        uint16 assetIndex_,
        uint256 capacityOffset_
    ) external {
        require(_msgSender() == assetInfoMap[assetIndex_].recipient, 
                "Only recipient can change");
        assetInfoMap[assetIndex_].futureCapacityOffset = capacityOffset_;
    }

    function changeTokenPrice(
        uint16 assetIndex_,
        uint256 tokenPrice_
    ) external onlyUpdater {
        assetInfoMap[assetIndex_].futureTokenPrice = tokenPrice_;
    }

    function getCurrentWeek() public view returns(uint256) {
        return (now + (4 days)) / (7 days);  // 4 days is the offset.
    }

    function getPremiumRate(uint16 assetIndex_, address who_) public view returns(uint256) {
        IRetailPremiumCalculator(retailPremiumCalculator).getPremiumRate(assetIndex_, who_);
    }

    // Step 1.
    function updateAsset(uint16 assetIndex_) external lock onlyUpdater {
        uint256 currentWeek = getCurrentWeek();

        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];

        require(assetInfo.weekUpdated < currentWeek, "Already called");

        // Uses future configurations.
        assetInfo.capacityOffset = assetInfo.futureCapacityOffset;
        assetInfo.tokenPrice = assetInfo.futureTokenPrice;

        uint256 sellerAssetBalance = ISeller(registry.seller()).assetBalance(assetIndex_);

        uint256 actualSubscription = assetInfo.capacityOffset.add(
            assetInfo.subscriptionBase).add(
                assetInfo.subscriptionAsset.mul(assetInfo.tokenPrice).div(PRICE_BASE));

        if (actualSubscription > sellerAssetBalance) {
            assetInfo.refundRatio = actualSubscription.sub(sellerAssetBalance).mul(REFUND_BASE).div(actualSubscription);
        } else {
            assetInfo.refundRatio = 0;
        }

        assetInfo.subscriptionBase = 0;
        assetInfo.subscriptionAsset = 0;

        assetInfoMap[assetIndex_].weekUpdated = currentWeek;  // This week.
    }

    // Step 2.
    function updateUser(uint16 assetIndex_, address who_) external lock onlyUpdater {
        uint256 currentWeek = getCurrentWeek();

        AssetInfo storage assetInfo = assetInfoMap[assetIndex_];
        UserInfo storage userInfo = userInfoMap[assetIndex_][who_];
        Subscription storage subscription = subscriptionByUser[assetIndex_][who_];

        require(assetInfoMap[assetIndex_].weekUpdated == currentWeek, "updateAsset first");
        require(userInfo.weekUpdated < currentWeek, "Already called");

        // Maybe refund to user.
        // NOTE: We pay recipient for the last week's premium at this week after refunding.
        if (assetInfo.refundRatio > 0) {
            uint256 refundBase = userInfo.premiumBase.mul(assetInfo.refundRatio).div(REFUND_BASE);
            userInfo.balanceBase = userInfo.balanceBase.add(refundBase);
            IERC20(registry.baseToken()).safeTransfer(assetInfo.recipient, userInfo.premiumBase.sub(refundBase));
            emit RefundBase(who_, assetIndex_, refundBase);

            if (assetInfo.token != address(0)) {
                uint256 refundAsset = userInfo.premiumAsset.mul(assetInfo.refundRatio).div(REFUND_BASE);
                userInfo.balanceAsset = userInfo.balanceAsset.add(refundAsset);
                IERC20(assetInfo.token).safeTransfer(assetInfo.recipient, userInfo.premiumAsset.sub(refundAsset));
                emit RefundAsset(who_, assetIndex_, refundAsset);
            }
        }

        // Maybe deduct premium as base.
        uint256 premiumBase = subscription.futureBase.mul(
                getPremiumRate(assetIndex_, who_)).div(registry.PREMIUM_BASE());
        if (userInfo.balanceBase >= premiumBase) {
            userInfo.balanceBase = userInfo.balanceBase.sub(premiumBase);
            userInfo.premiumBase = premiumBase;
            subscription.currentBase = subscription.futureBase;
            assetInfo.subscriptionBase = assetInfo.subscriptionBase.add(subscription.currentBase);

            emit DeductBase(who_, assetIndex_, subscription.currentBase, premiumBase);
        } else {
            userInfo.premiumBase = 0;
            subscription.currentBase = 0;
            subscription.futureBase = 0;
        }

        // Maybe deduct premium as asset.
        if (assetInfo.token != address(0)) {
            uint256 premiumAsset = subscription.futureAsset.mul(
                getPremiumRate(assetIndex_, who_)).div(registry.PREMIUM_BASE()).mul(PRICE_BASE).div(assetInfo.tokenPrice);
            if (userInfo.balanceAsset >= premiumAsset) {
                userInfo.balanceAsset = userInfo.balanceAsset.sub(premiumAsset);
                userInfo.premiumAsset = premiumAsset;
                subscription.currentAsset = subscription.futureAsset;
                assetInfo.subscriptionAsset = assetInfo.subscriptionAsset.add(subscription.currentAsset);

                emit DeductAsset(who_, assetIndex_, subscription.currentAsset, premiumAsset);
            } else {
                userInfo.premiumAsset = 0;
                subscription.currentAsset = 0;
                subscription.futureAsset = 0;
            }
        }

        userInfo.weekUpdated = currentWeek;  // This week.
    }

    function depositBase(uint16 assetIndex_, uint256 amount_) external lock {
        require(amount_ > 0, "amount_ is zero");

        IERC20(registry.baseToken()).safeTransferFrom(_msgSender(), address(this), amount_);
        userInfoMap[assetIndex_][_msgSender()].balanceBase = userInfoMap[assetIndex_][_msgSender()].balanceBase.add(amount_);

        emit DepositBase(_msgSender(), assetIndex_, amount_);
    }

    function depositAsset(uint16 assetIndex_, uint256 amount_) external lock {
        require(assetInfoMap[assetIndex_].token != address(0), "token is zero");
        require(amount_ > 0, "amount_ is zero");

        IERC20(assetInfoMap[assetIndex_].token).safeTransferFrom(
            _msgSender(), address(this), amount_);
        userInfoMap[assetIndex_][_msgSender()].balanceAsset =
            userInfoMap[assetIndex_][_msgSender()].balanceAsset.add(amount_);

        emit DepositAsset(_msgSender(), assetIndex_, amount_);
    }

    function withdrawBase(uint16 assetIndex_, uint256 amount_) external lock {
        require(amount_ > 0, "amount_ is zero");
        require(userInfoMap[assetIndex_][_msgSender()].balanceBase >= amount_, "not enough balance");

        IERC20(registry.baseToken()).safeTransfer(_msgSender(), amount_);
        userInfoMap[assetIndex_][_msgSender()].balanceBase = userInfoMap[assetIndex_][_msgSender()].balanceBase.sub(amount_);

        emit WithdrawBase(_msgSender(), assetIndex_, amount_);
    }

    function withdrawAsset(uint16 assetIndex_, uint256 amount_) external lock {
        require(assetInfoMap[assetIndex_].token != address(0), "token is zero");
        require(amount_ > 0, "amount_ is zero");
        require(userInfoMap[assetIndex_][_msgSender()].balanceAsset >= amount_, "not enough balance");

        IERC20(assetInfoMap[assetIndex_].token).safeTransfer(_msgSender(), amount_);
        userInfoMap[assetIndex_][_msgSender()].balanceAsset = userInfoMap[assetIndex_][_msgSender()].balanceAsset.sub(amount_);

        emit WithdrawAsset(_msgSender(), assetIndex_, amount_);
    }

    function subscribeBase(uint16 assetIndex_, uint256 amount_) external {
        require(amount_ > 0, "amount_ is zero");

        subscriptionByAsset[assetIndex_].futureBase = subscriptionByAsset[assetIndex_].futureBase.add(amount_);
        subscriptionByUser[assetIndex_][_msgSender()].futureBase = subscriptionByUser[assetIndex_][_msgSender()].futureBase.add(amount_);
        emit SubscribeBase(_msgSender(), assetIndex_, amount_);
    }

    function unsubscribeBase(uint16 assetIndex_, uint256 amount_) external {
        require(amount_ > 0, "amount_ is zero");

        subscriptionByAsset[assetIndex_].futureBase = subscriptionByAsset[assetIndex_].futureBase.sub(amount_);
        subscriptionByUser[assetIndex_][_msgSender()].futureBase = subscriptionByUser[assetIndex_][_msgSender()].futureBase.sub(amount_);
        emit UnsubscribeBase(_msgSender(), assetIndex_, amount_);
    }

    function subscribeAsset(uint16 assetIndex_, uint256 amount_) external {
        require(assetInfoMap[assetIndex_].token != address(0), "token is zero");
        require(amount_ > 0, "amount_ is zero");

        subscriptionByAsset[assetIndex_].futureAsset = subscriptionByAsset[assetIndex_].futureAsset.add(amount_);
        subscriptionByUser[assetIndex_][_msgSender()].futureAsset = subscriptionByUser[assetIndex_][_msgSender()].futureAsset.add(amount_);
        emit SubscribeAsset(_msgSender(), assetIndex_, amount_);
    }

    function unsubscribeAsset(uint16 assetIndex_, uint256 amount_) external {
        require(assetInfoMap[assetIndex_].token != address(0), "token is zero");
        require(amount_ > 0, "amount_ is zero");

        subscriptionByAsset[assetIndex_].futureAsset = subscriptionByAsset[assetIndex_].futureAsset.sub(amount_);
        subscriptionByUser[assetIndex_][_msgSender()].futureAsset = subscriptionByUser[assetIndex_][_msgSender()].futureAsset.sub(amount_);
        emit UnsubscribeAsset(_msgSender(), assetIndex_, amount_);
    }
}
