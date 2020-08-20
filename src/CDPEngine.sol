/// CDPEngine.sol -- CDP database

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.6.7;

contract CDPEngine {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "CDPEngine/account-not-authorized");
        _;
    }

    // Who can transfer collateral & debt in/out of a CDP
    mapping(address => mapping (address => uint)) public cdpRights;
    /**
     * @notice Allow an address to modify your CDP
     * @param account Account to give CDP permissions to
     */
    function approveCDPModification(address account) external {
        cdpRights[msg.sender][account] = 1;
        emit ApproveCDPModification(msg.sender, account);
    }
    /**
     * @notice Deny an address the rights to modify your CDP
     * @param account Account to give CDP permissions to
     */
    function denyCDPModification(address account) external {
        cdpRights[msg.sender][account] = 0;
        emit DenyCDPModification(msg.sender, account);
    }
    /**
    * @notice Checks whether msg.sender has the right to modify a CDP
    **/
    function canModifyCDP(address cdp, address account) public view returns (bool) {
        return either(cdp == account, cdpRights[cdp][account] == 1);
    }

    // --- Data ---
    struct CollateralType {
        // Total debt issued for this specific collateral type
        uint256 debtAmount;        // [wad]
        // Accumulator for interest accrued on this collateral type
        uint256 accumulatedRate;  // [ray]
        // Floor price at which a CDP is allowed to generate debt
        uint256 safetyPrice;       // [ray]
        // Maximum amount of debt that can be generated with this collateral type
        uint256 debtCeiling;       // [rad]
        // Minimum amount of debt that must be generated by a CDP using this collateral
        uint256 debtFloor;         // [rad]
        // Price at which a CDP gets liquidated
        uint256 liquidationPrice;  // [ray]
    }
    struct CDP {
        // Total amount of collateral locked in a CDP
        uint256 lockedCollateral;  // [wad]
        // Total amount of debt generated by a CDP
        uint256 generatedDebt;     // [wad]
    }

    // Data about each collateral type
    mapping (bytes32 => CollateralType)            public collateralTypes;
    // Data about each CDP
    mapping (bytes32 => mapping (address => CDP )) public cdps;
    // Balance of each collateral type
    mapping (bytes32 => mapping (address => uint)) public tokenCollateral;  // [wad]
    // Internal balance of system coins
    mapping (address => uint)                      public coinBalance;      // [rad]
    // Amount of debt held by an account. Coins & debt are like matter and antimatter. They nullify each other
    mapping (address => uint)                      public debtBalance;      // [rad]

    // Total amount of debt (coins) currently issued
    uint256  public globalDebt;          // [rad]
    // 'Bad' debt that's not covered by collateral
    uint256  public globalUnbackedDebt;  // [rad]
    // Maximum amount of debt that can be issued
    uint256  public globalDebtCeiling;   // [rad]
    // Access flag, indicates whether this contract is still active
    uint256  public contractEnabled;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ApproveCDPModification(address sender, address account);
    event DenyCDPModification(address sender, address account);
    event InitializeCollateralType(bytes32 collateralType);
    event ModifyParameters(bytes32 parameter, uint data);
    event ModifyParameters(bytes32 collateralType, bytes32 parameter, uint data);
    event DisableContract();
    event ModifyCollateralBalance(bytes32 collateralType, address account, int256 wad);
    event TransferCollateral(bytes32 collateralType, address src, address dst, uint256 wad);
    event TransferInternalCoins(address src, address dst, uint256 rad);
    event ModifyCDPCollateralization(
        bytes32 collateralType,
        address cdp,
        address collateralSource,
        address debtDestination,
        int deltaCollateral,
        int deltaDebt,
        uint lockedCollateral,
        uint generatedDebt,
        uint globalDebt
    );
    event TransferCDPCollateralAndDebt(
        bytes32 collateralType,
        address src,
        address dst,
        int deltaCollateral,
        int deltaDebt,
        uint srcLockedCollateral,
        uint srcGeneratedDebt,
        uint dstLockedCollateral,
        uint dstGeneratedDebt
    );
    event ConfiscateCDPCollateralAndDebt(
        bytes32 collateralType,
        address cdp,
        address collateralCounterparty,
        address debtCounterparty,
        int deltaCollateral,
        int deltaDebt,
        uint globalUnbackedDebt
    );
    event SettleDebt(uint rad, uint debtBalance, uint coinBalance, uint globalUnbackedDebt, uint globalDebt);
    event CreateUnbackedDebt(
        address debtDestination,
        address coinDestination,
        uint rad,
        uint debtDstBalance,
        uint coinDstBalance,
        uint globalUnbackedDebt,
        uint globalDebt
    );
    event UpdateAccumulatedRate(
        bytes32 collateralType,
        address surplusDst,
        int rateMultiplier,
        uint dstCoinBalance,
        uint globalDebt
    );

    // --- Init ---
    constructor() public {
        authorizedAccounts[msg.sender] = 1;
        contractEnabled = 1;
        emit AddAuthorization(msg.sender);
    }

    // --- Math ---
    function addition(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function addition(int x, int y) internal pure returns (int z) {
        z = x + y;
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function subtract(uint x, int y) internal pure returns (uint z) {
        z = x - uint(y);
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function subtract(int x, int y) internal pure returns (int z) {
        z = x - y;
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function multiply(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }
    function addition(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function subtract(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---

    /**
     * @notice Creates a brand new collateral type
     * @param collateralType Collateral type name (e.g ETH-A, TBTC-B)
     */
    function initializeCollateralType(bytes32 collateralType) external isAuthorized {
        require(collateralTypes[collateralType].accumulatedRate == 0, "CDPEngine/collateral-type-already-exists");
        collateralTypes[collateralType].accumulatedRate = 10 ** 27;
        emit InitializeCollateralType(collateralType);
    }
    /**
     * @notice Modify general uint params
     * @param parameter The name of the parameter modified
     * @param data New value for the parameter
     */
    function modifyParameters(bytes32 parameter, uint data) external isAuthorized {
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");
        if (parameter == "globalDebtCeiling") globalDebtCeiling = data;
        else revert("CDPEngine/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /**
     * @notice Modify collateral specific params
     * @param collateralType Collateral type we modify params for
     * @param parameter The name of the parameter modified
     * @param data New value for the parameter
     */
    function modifyParameters(
        bytes32 collateralType,
        bytes32 parameter,
        uint data
    ) external isAuthorized {
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");
        if (parameter == "safetyPrice") collateralTypes[collateralType].safetyPrice = data;
        else if (parameter == "liquidationPrice") collateralTypes[collateralType].liquidationPrice = data;
        else if (parameter == "debtCeiling") collateralTypes[collateralType].debtCeiling = data;
        else if (parameter == "debtFloor") collateralTypes[collateralType].debtFloor = data;
        else revert("CDPEngine/modify-unrecognized-param");
        emit ModifyParameters(collateralType, parameter, data);
    }
    /**
     * @notice Disable this contract (normally called by GlobalSettlement)
     */
    function disableContract() external isAuthorized {
        contractEnabled = 0;
        emit DisableContract();
    }

    // --- Fungibility ---
    /**
     * @notice Join/exit collateral into and and out of the system
     * @param collateralType Collateral type we join/exit
     * @param account Account that gets credited/debited
     * @param wad Amount of collateral [wad]
     */
    function modifyCollateralBalance(
        bytes32 collateralType,
        address account,
        int256 wad
    ) external isAuthorized {
        tokenCollateral[collateralType][account] = addition(tokenCollateral[collateralType][account], wad);
        emit ModifyCollateralBalance(collateralType, account, wad);
    }
    /**
     * @notice Transfer collateral between accounts
     * @param collateralType Collateral type transferred
     * @param src Collateral source
     * @param dst Collateral destination
     * @param wad Amount of collateral transferred [wad]
     */
    function transferCollateral(
        bytes32 collateralType,
        address src,
        address dst,
        uint256 wad
    ) external {
        require(canModifyCDP(src, msg.sender), "CDPEngine/not-allowed");
        tokenCollateral[collateralType][src] = subtract(tokenCollateral[collateralType][src], wad);
        tokenCollateral[collateralType][dst] = addition(tokenCollateral[collateralType][dst], wad);
        emit TransferCollateral(collateralType, src, dst, wad);
    }
    /**
     * @notice Transfer internal coins (does not affect external balances from Coin.sol)
     * @param src Coins source
     * @param dst Coins destination
     * @param rad Amount of coins transferred [rad]
     */
    function transferInternalCoins(address src, address dst, uint256 rad) external {
        require(canModifyCDP(src, msg.sender), "CDPEngine/not-allowed");
        coinBalance[src] = subtract(coinBalance[src], rad);
        coinBalance[dst] = addition(coinBalance[dst], rad);
        emit TransferInternalCoins(src, dst, rad);
    }

    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- CDP Manipulation ---
    /**
     * @notice Add/remove collateral or put back/generate more debt in a CDP
     * @param collateralType Type of collateral to withdraw/deposit in and from the CDP
     * @param cdp Target CDP
     * @param collateralSource Account we take collateral from/put collateral into
     * @param debtDestination Account from which we credit/debit coins and debt
     * @param deltaCollateral Amount of collateral added/extract from the CDP [wad]
     * @param deltaDebt Amount of debt to generate/repay [wad]
     */
    function modifyCDPCollateralization(
        bytes32 collateralType,
        address cdp,
        address collateralSource,
        address debtDestination,
        int deltaCollateral,
        int deltaDebt
    ) external {
        // system is live
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");

        CDP memory cdpData = cdps[collateralType][cdp];
        CollateralType memory collateralTypeData = collateralTypes[collateralType];
        // collateral type has been initialised
        require(collateralTypeData.accumulatedRate != 0, "CDPEngine/collateral-type-not-initialized");

        cdpData.lockedCollateral      = addition(cdpData.lockedCollateral, deltaCollateral);
        cdpData.generatedDebt         = addition(cdpData.generatedDebt, deltaDebt);
        collateralTypeData.debtAmount = addition(collateralTypeData.debtAmount, deltaDebt);

        int deltaAdjustedDebt = multiply(collateralTypeData.accumulatedRate, deltaDebt);
        uint totalDebtIssued  = multiply(collateralTypeData.accumulatedRate, cdpData.generatedDebt);
        globalDebt            = addition(globalDebt, deltaAdjustedDebt);

        // either debt has decreased, or debt ceilings are not exceeded
        require(
          either(
            deltaDebt <= 0,
            both(multiply(collateralTypeData.debtAmount, collateralTypeData.accumulatedRate) <= collateralTypeData.debtCeiling,
              globalDebt <= globalDebtCeiling)
            ),
          "CDPEngine/ceiling-exceeded"
        );
        // cdp is either less risky than before, or it is safe
        require(
          either(
            both(deltaDebt <= 0, deltaCollateral >= 0),
            totalDebtIssued <= multiply(cdpData.lockedCollateral, collateralTypeData.safetyPrice)
          ),
          "CDPEngine/not-safe"
        );

        // cdp is either more safe, or the owner consents
        require(either(both(deltaDebt <= 0, deltaCollateral >= 0), canModifyCDP(cdp, msg.sender)), "CDPEngine/not-allowed-to-modify-cdp");
        // collateral src consents
        require(either(deltaCollateral <= 0, canModifyCDP(collateralSource, msg.sender)), "CDPEngine/not-allowed-collateral-src");
        // debt dst consents
        require(either(deltaDebt >= 0, canModifyCDP(debtDestination, msg.sender)), "CDPEngine/not-allowed-debt-dst");

        // cdp has no debt, or a non-dusty amount
        require(either(cdpData.generatedDebt == 0, totalDebtIssued >= collateralTypeData.debtFloor), "CDPEngine/dust");

        tokenCollateral[collateralType][collateralSource] =
          subtract(tokenCollateral[collateralType][collateralSource], deltaCollateral);

        coinBalance[debtDestination] = addition(coinBalance[debtDestination], deltaAdjustedDebt);

        cdps[collateralType][cdp] = cdpData;
        collateralTypes[collateralType] = collateralTypeData;

        emit ModifyCDPCollateralization(
            collateralType,
            cdp,
            collateralSource,
            debtDestination,
            deltaCollateral,
            deltaDebt,
            cdpData.lockedCollateral,
            cdpData.generatedDebt,
            globalDebt
        );
    }

    // --- CDP Fungibility ---
    /**
     * @notice Transfer collateral and/or debt between CDPs
     * @param collateralType Collateral type transferred between CDPs
     * @param src Source CDP
     * @param dst Destination CDP
     * @param deltaCollateral Amount of collateral to take/add into src and give/take from dst [wad]
     * @param deltaDebt Amount of debt to take/add into src and give/take from dst [wad]
     */
    function transferCDPCollateralAndDebt(
        bytes32 collateralType,
        address src,
        address dst,
        int deltaCollateral,
        int deltaDebt
    ) external {
        CDP storage srcCDP = cdps[collateralType][src];
        CDP storage dstCDP = cdps[collateralType][dst];
        CollateralType storage collateralType_ = collateralTypes[collateralType];

        srcCDP.lockedCollateral = subtract(srcCDP.lockedCollateral, deltaCollateral);
        srcCDP.generatedDebt    = subtract(srcCDP.generatedDebt, deltaDebt);
        dstCDP.lockedCollateral = addition(dstCDP.lockedCollateral, deltaCollateral);
        dstCDP.generatedDebt    = addition(dstCDP.generatedDebt, deltaDebt);

        uint srcTotalDebtIssued = multiply(srcCDP.generatedDebt, collateralType_.accumulatedRate);
        uint dstTotalDebtIssued = multiply(dstCDP.generatedDebt, collateralType_.accumulatedRate);

        // both sides consent
        require(both(canModifyCDP(src, msg.sender), canModifyCDP(dst, msg.sender)), "CDPEngine/not-allowed");

        // both sides safe
        require(srcTotalDebtIssued <= multiply(srcCDP.lockedCollateral, collateralType_.safetyPrice), "CDPEngine/not-safe-src");
        require(dstTotalDebtIssued <= multiply(dstCDP.lockedCollateral, collateralType_.safetyPrice), "CDPEngine/not-safe-dst");

        // both sides non-dusty
        require(either(srcTotalDebtIssued >= collateralType_.debtFloor, srcCDP.generatedDebt == 0), "CDPEngine/dust-src");
        require(either(dstTotalDebtIssued >= collateralType_.debtFloor, dstCDP.generatedDebt == 0), "CDPEngine/dust-dst");

        emit TransferCDPCollateralAndDebt(
            collateralType,
            src,
            dst,
            deltaCollateral,
            deltaDebt,
            srcCDP.lockedCollateral,
            srcCDP.generatedDebt,
            dstCDP.lockedCollateral,
            dstCDP.generatedDebt
        );
    }

    // --- CDP Confiscation ---
    /**
     * @notice Normally used by the LiquidationEngine in order to confiscate collateral and
       debt from a CDP and give them to someone else
     * @param collateralType Collateral type the CDP has locked inside
     * @param cdp Target CDP
     * @param collateralCounterparty Who we take/give collateral to
     * @param debtCounterparty Who we take/give debt to
     * @param deltaCollateral Amount of collateral taken/added into the CDP [wad]
     * @param deltaDebt Amount of collateral taken/added into the CDP [wad]
     */
    function confiscateCDPCollateralAndDebt(
        bytes32 collateralType,
        address cdp,
        address collateralCounterparty,
        address debtCounterparty,
        int deltaCollateral,
        int deltaDebt
    ) external isAuthorized {
        CDP storage cdp_ = cdps[collateralType][cdp];
        CollateralType storage collateralType_ = collateralTypes[collateralType];

        cdp_.lockedCollateral = addition(cdp_.lockedCollateral, deltaCollateral);
        cdp_.generatedDebt = addition(cdp_.generatedDebt, deltaDebt);
        collateralType_.debtAmount = addition(collateralType_.debtAmount, deltaDebt);

        int deltaTotalIssuedDebt = multiply(collateralType_.accumulatedRate, deltaDebt);

        tokenCollateral[collateralType][collateralCounterparty] = subtract(
          tokenCollateral[collateralType][collateralCounterparty],
          deltaCollateral
        );
        debtBalance[debtCounterparty] = subtract(
          debtBalance[debtCounterparty],
          deltaTotalIssuedDebt
        );
        globalUnbackedDebt = subtract(
          globalUnbackedDebt,
          deltaTotalIssuedDebt
        );

        emit ConfiscateCDPCollateralAndDebt(
            collateralType,
            cdp,
            collateralCounterparty,
            debtCounterparty,
            deltaCollateral,
            deltaDebt,
            globalUnbackedDebt
        );
    }

    // --- Settlement ---
    /**
     * @notice Nullify an amount of coins with an equal amount of debt
     * @param rad Amount of debt & coins to destroy [rad]
     */
    function settleDebt(uint rad) external {
        address account       = msg.sender;
        debtBalance[account]  = subtract(debtBalance[account], rad);
        coinBalance[account]  = subtract(coinBalance[account], rad);
        globalUnbackedDebt    = subtract(globalUnbackedDebt, rad);
        globalDebt            = subtract(globalDebt, rad);
        emit SettleDebt(rad, debtBalance[account], coinBalance[account], globalUnbackedDebt, globalDebt);
    }
    /**
     * @notice Usually called by CoinSavingsAccount in order to create unbacked debt
     * @param debtDestination Usually AccountingEngine that can settle dent with surplus
     * @param coinDestination Usually CoinSavingsAccount who passes the new coins to depositors
     * @param rad Amount of debt to create [rad]
     */
    function createUnbackedDebt(
        address debtDestination,
        address coinDestination,
        uint rad
    ) external isAuthorized {
        debtBalance[debtDestination]  = addition(debtBalance[debtDestination], rad);
        coinBalance[coinDestination]  = addition(coinBalance[coinDestination], rad);
        globalUnbackedDebt            = addition(globalUnbackedDebt, rad);
        globalDebt                    = addition(globalDebt, rad);
        emit CreateUnbackedDebt(
            debtDestination,
            coinDestination,
            rad,
            debtBalance[debtDestination],
            coinBalance[coinDestination],
            globalUnbackedDebt,
            globalDebt
        );
    }

    // --- Rates ---
    /**
     * @notice Usually called by TaxCollector in order to accrue interest on a specific collateral type
     * @param collateralType Collateral type we accrue interest for
     * @param surplusDst Destination for amount of surplus created by applying the interest rate
       to debt created by CDPs with 'collateralType'
     * @param rateMultiplier Multiplier applied to the debtAmount in order to calculate the surplus [ray]
     */
    function updateAccumulatedRate(
        bytes32 collateralType,
        address surplusDst,
        int rateMultiplier
    ) external isAuthorized {
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");
        CollateralType storage collateralType_ = collateralTypes[collateralType];
        collateralType_.accumulatedRate        = addition(collateralType_.accumulatedRate, rateMultiplier);
        int deltaSurplus                       = multiply(collateralType_.debtAmount, rateMultiplier);
        coinBalance[surplusDst]                = addition(coinBalance[surplusDst], deltaSurplus);
        globalDebt                             = addition(globalDebt, deltaSurplus);
        emit UpdateAccumulatedRate(
            collateralType,
            surplusDst,
            rateMultiplier,
            coinBalance[surplusDst],
            globalDebt
        );
    }
}
