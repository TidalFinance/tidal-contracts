const { expectRevert, time } = require('@openzeppelin/test-helpers');
const ethers = require('ethers');

const AssetManager = artifacts.require('AssetManager');
const Bonus = artifacts.require('Bonus');
const Buyer = artifacts.require('Buyer');
const Guarantor = artifacts.require('Guarantor');
const MockERC20 = artifacts.require('MockERC20');
const PremiumCalculator = artifacts.require('PremiumCalculator');
const Registry = artifacts.require('Registry');
const Seller = artifacts.require('Seller');
const TidalToken = artifacts.require('TidalToken');

function encodeParameters(types, values) {
    const abi = new ethers.utils.AbiCoder();
    return abi.encode(types, values);
}

contract('Buyer', ([dev, seller0, buyer0]) => {

    beforeEach(async () => {
        this.registry = await Registry.new({ from: dev });
        this.assetManager = await AssetManager.new({ from: dev });
        this.bonus = await Bonus.new(this.registry.address, { from: dev });
        this.buyer = await Buyer.new(this.registry.address, { from: dev });
        this.guarantor = await Guarantor.new(this.registry.address, { from: dev });
        this.premiumCalculator = await PremiumCalculator.new(this.registry.address, { from: dev });
        this.seller = await Seller.new(this.registry.address, { from: dev });
        this.tidal = await TidalToken.new({ from: dev });

        this.testUSDC = await MockERC20("TestUSDC", "USDC", 1000000, { from: dev });
        await this.testUSDC.transfer(buyer0, 100000, { from: dev });
        await this.testUSDC.transfer(seller0, 900000, { from: dev });

        await this.registry.setBaseToken(this.testUSDC.address, {from: dev});
        await this.registry.setBonus(this.bonus.address, {from: dev});
        await this.registry.setBuyer(this.buyer.address, { from: dev });
        await this.registry.setGuarantor(this.guarantor.address, { from: dev });
        await this.registry.setSeller(this.seller.address, { from: dev });
        await this.registry.setPlatform(dev, { from: dev });
        await this.registry.setTidalToken(this.tidal.address, { from: dev });

        // Setup asset 0 (no guarantor).
        await this.assetManager.setAsset(0, address(0), 0, { from: dev });
        await this.assetManager.resetIndexesByCategory(0, { from: dev });

        // Setup premiumCalculator.
        await this.premiumCalculator(0, 500, { from: dev });  // 0.05% per week.

        // Setup bonus and prepare enough TIDAL.
        await this.bonus.setBonusPerAssetOfS(0, 10000, { from: dev });
        await this.tidal.transfer(this.bonus.address, 50000, { from: dev });

        // Setup buyer address.
        await this.buyer.setBuyerAssetIndexPlusOne(0, buyer0, { from: dev });
    });

    const updateAssets = async () => {
        await this.buyer.beforeUpdate({ from: dev });
        await this.bonus.updateGuarantorBonus(0, { from: dev });
        await this.bonus.updateSellerBonus(0, { from: dev });
        await this.guarantor.updatePremium(0, { from: dev });
        await this.seller.updatePremium(0, { from: dev });
    }

    const updateBuyer = async() => {
        await this.buyer.update(buyer0, { from: dev });
    }

    const updateSeller = async() => {
        await this.seller.update();
    }

    it('should work', async () => {
        await updateAssets();
        await updateBuyer();

        // Buyer deposit some balance, and subscribe.
        await this.buyer.deposit(100000, { from: buyer0 });
        // Paying 5 USDC per week to cover 10000 USDC assets.
        await this.buyer.subscribe(0, 10000, { from: buyer0 });

        // Seller deposit some balance, and set up basket.
        await this.seller.deposit(0, 9000, { from: seller0 });  // Only 9000
        await this.seller.changeBasket(0, [0], { from: seller0 });
        // Bascket should be changed immediately

        await time.increase(time.duration.days(7));

        await updateAssets();
        await updateBuyer();
        await updateSeller();

        // Now buyer should have 9995 balance.
    });
});
