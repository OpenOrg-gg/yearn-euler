// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

import "../interfaces/ITradeFactory.sol";
import "@openzeppelin/contracts/math/Math.sol";

interface IEulerEulDistributor{
    function claim(address account, address token, uint claimable, bytes32[] calldata proof, address stake) external;
}

interface IEulerEulStakes {
    function staked(address account, address underlying) external view returns (uint);
    struct StakeOp {
        address underlying;
        int amount;
    }
    function stake(StakeOp[] memory ops) external;
    function stakeGift(address beneficiary, address underlying, uint amount) external;
    function stakePermit(StakeOp[] memory ops, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}

interface IEulerMarkets {
    function activateMarket(address underlying) external returns (address);
    function activatePToken(address underlying) external returns (address);
    function underlyingToEToken(address underlying) external view returns (address);
    function underlyingToDToken(address underlying) external view returns (address);
    function underlyingToPToken(address underlying) external view returns (address);
    function eTokenToUnderlying(address eToken) external view returns (address underlying);
    function eTokenToDToken(address eToken) external view returns (address dTokenAddr);
    function interestRateModel(address underlying) external view returns (uint);
    function interestRate(address underlying) external view returns (int96);
    function interestAccumulator(address underlying) external view returns (uint);
    function reserveFee(address underlying) external view returns (uint32);
    function getPricingConfig(address underlying) external view returns (uint16 pricingType, uint32 pricingParameters, address pricingForwarded);
    function getEnteredMarkets(address account) external view returns (address[] memory);
    function enterMarket(uint subAccountId, address newMarket) external;
    function exitMarket(uint subAccountId, address oldMarket) external;
}

interface IEulerEToken {
    function underlyingAsset() external view returns (address);
    function totalSupply() external view returns (uint);
    function totalSupplyUnderlying() external view returns (uint);
    function balanceOf(address account) external view returns (uint);
    function balanceOfUnderlying(address account) external view returns (uint);
    function reserveBalance() external view returns (uint);
    function reserveBalanceUnderlying() external view returns (uint);
    function convertBalanceToUnderlying(uint balance) external view returns (uint);
    function convertUnderlyingToBalance(uint underlyingAmount) external view returns (uint);
    function touch() external;
    function deposit(uint subAccountId, uint amount) external;
    function withdraw(uint subAccountId, uint amount) external;
    function mint(uint subAccountId, uint amount) external;
    function burn(uint subAccountId, uint amount) external;
    function approve(address spender, uint amount) external returns (bool);
    function approveSubAccount(uint subAccountId, address spender, uint amount) external returns (bool);
    function allowance(address holder, address spender) external view returns (uint);
    function transfer(address to, uint amount) external returns (bool);
    function transferFromMax(address from, address to) external returns (bool);
    function transferFrom(address from, address to, uint amount) external returns (bool);
}

interface IEulerDToken {
    function decimals() external view returns (uint8);
    function underlyingAsset() external view returns (address);
    function totalSupply() external view returns (uint);
    function balanceOf(address account) external view returns (uint);
    function borrow(uint subAccountId, uint amount) external;
    function repay(uint subAccountId, uint amount) external;
    function approveDebt(uint subAccountId, address spender, uint amount) external returns (bool);
    function debtAllowance(address holder, address spender) external view returns (uint);
    function transfer(address to, uint amount) external returns (bool);
    function transferFrom(address from, address to, uint amount) external returns (bool);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public tradeFactory = address(0);
    address public constant strategistMultisig = address(0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7);
    address public eulerHoldings = address(0x27182842E098f60e3D576794A5bFFb0777E025d3);
    IEulerDToken public constant debtToken = IEulerDToken(0x84721A3dB22EB852233AEAE74f9bC8477F8bcc42);
    IEulerEToken public constant eToken = IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);
    IERC20 public constant eulToken = IERC20(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);
    IEulerEulDistributor public distributor;
    IEulerMarkets public constant marketsModule = IEulerMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);
    address public assetMarket = address(want);
    uint256 public keepEul;
    uint256 public basis = 10000;
    bool public emergencyMode;
    bool public leaveDebtMode;

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        marketsModule.enterMarket(0, address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
        want.approve(address(marketsModule), type(uint).max);
        want.approve(address(eToken), type(uint).max);
        want.approve(address(0x27182842E098f60e3D576794A5bFFb0777E025d3), type(uint).max);
        eToken.approve(address(marketsModule), type(uint).max);
        keepEul = 500;
        emergencyMode = false;
        leaveDebtMode = true;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // V1 Euler Strategies are deposit only, no mining and use ySwaps to lower management overhead so one can easily be established for any vault.
        // High value vaults should switch to V2 once mining is claimable.
        return "StrategyEulerUSDCV1";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        uint256 depositedBalance = eToken.balanceOfUnderlying(address(this)); //balance of for deposited tokens is returned in tokens, need balanceOfUnderlying

        return balanceOfWant().add(depositedBalance);
    }


    //Organizational Functions

    function _withdrawFromMarket(uint256 _amount) internal {
        eToken.withdraw(0,_amount);
    }

    function balanceOfWant() public view returns(uint256){
        return want.balanceOf(address(this));
    }
    function balanceOfUnderlyingToWant() public view returns (uint256){
        return eToken.balanceOfUnderlying(address(this));
    }

    function availableBalanceOnEuler() public view returns (uint256){
        return want.balanceOf(eulerHoldings);
    }

    function withdrawSome(uint256 _amount) internal returns(uint256){
        uint256 preBalance = balanceOfWant();
        eToken.withdraw(0, _amount);
        uint256 postBalance = balanceOfWant();

        return postBalance.sub(preBalance);
    }

function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position

        //grab the estimate total debt from the vault
        uint256 _vaultDebt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        _profit = _totalAssets > _vaultDebt ? _totalAssets.sub(_vaultDebt) : 0;

        //free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.
        uint256 _amountFreed;
        uint256 _toLiquidate = _debtOutstanding.add(_profit);
        uint256 _wantBalance = balanceOfWant();
        uint256 _eulerBalance = availableBalanceOnEuler();
        if(_toLiquidate > _eulerBalance){
            require(leaveDebtMode);
            _toLiquidate = _eulerBalance;
        }

        _amountFreed = withdrawSome(_toLiquidate);

        _totalAssets = estimatedTotalAssets();
        _debtPayment = Math.min(_debtOutstanding, _amountFreed);
        _loss = _loss.add(
            _vaultDebt > _totalAssets ? _vaultDebt.sub(_totalAssets) : 0
        );

        if (_loss > _profit) {
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)

        //recheck that market hasn't changed or upgraded
        marketsModule.underlyingToEToken(address(want));

        if(emergencyMode == false){
            if(balanceOfWant() > 0){
                eToken.deposit(0, balanceOfWant());
            }
        }
    }

    function proofClaim(bytes32[] calldata _proof, address _distributor, uint256 _claimableEul) public onlyAuthorized {
       distributor = IEulerEulDistributor(_distributor);
       bytes32[] calldata proof = _proof;

        //check current Euler balance
        uint256 existingEul = eulToken.balanceOf(address(this));

        //claim Euler
        distributor.claim(address(this), address(eulToken), _claimableEul, proof, address(0));

        if(eulToken.balanceOf(address(this)) > existingEul) {
            uint256 remainder = eulToken.balanceOf(address(this)).sub(existingEul);

            //transfer some percent to treasury for voting
            uint256 amount = remainder.mul(keepEul).div(basis);
            eulToken.transfer(strategistMultisig, amount);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 preBalance = balanceOfWant();

        if(_amountNeeded <= availableBalanceOnEuler()){
            if(_amountNeeded > balanceOfWant()){
                if(_amountNeeded <= balanceOfUnderlyingToWant()){
                    _withdrawFromMarket(_amountNeeded);
                } else {
                    _withdrawFromMarket(type(uint).max);
                }
            }
        } else {
            _withdrawFromMarket(availableBalanceOnEuler());
        }

        uint256 totalAssets = want.balanceOf(address(this));

        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets.sub(preBalance);
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {

        //Euler special withdraw function to withdraw max available without missing fees that accumulate each block
        if(eToken.balanceOfUnderlying(address(this)) < availableBalanceOnEuler()){
            eToken.withdraw(0, type(uint).max);
        } else {
            eToken.withdraw(0, availableBalanceOnEuler());
        }
        return balanceOfWant();
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        if(eToken.balanceOf(address(this)) > 0){
            eToken.transfer(address(_newStrategy), eToken.balanceOf(address(this)));
        }

    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
    }

    // ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        // approve and set up trade factory
        eulToken.safeApprove(_tradeFactory, type(uint256).max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(address(eulToken), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();

    }
    function _removeTradeFactoryPermissions() internal {
        eulToken.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }

    // ----------------- MANAGEMENT FUNCTIONS ---------------------

    function setKeepEul(uint256 _keepEul) public onlyGovernance {
        keepEul = _keepEul;
    }

    function setFlag(bool _bool) public onlyAuthorized {
        emergencyMode = _bool;
    }

    function setLeaveDebt(bool _bool) public onlyAuthorized {
        leaveDebtMode = _bool;
    }

    function manualWithdraw(uint256 _amount) public onlyAuthorized {
        eToken.withdraw(0, _amount);
    }
}
