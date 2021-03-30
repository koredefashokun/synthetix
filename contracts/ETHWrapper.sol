pragma solidity ^0.5.16;

// Inheritance
import "./Owned.sol";
import "./interfaces/IAddressResolver.sol";
import "./interfaces/ISystemStatus.sol";
import "./interfaces/IETHWrapper.sol";
import "./interfaces/ISynth.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";
import "openzeppelin-solidity-2.3.0/contracts/utils/ReentrancyGuard.sol";

// Internal references
import "./interfaces/IIssuer.sol";
import "./interfaces/IExchangeRates.sol";
import "./interfaces/IFeePool.sol";
import "./MixinResolver.sol";
import "./MixinSystemSettings.sol";

// Libraries
import "openzeppelin-solidity-2.3.0/contracts/math/SafeMath.sol";
import "./SafeDecimalMath.sol";
import "hardhat/console.sol";

// Pausable
contract ETHWrapper is Owned, MixinResolver, MixinSystemSettings, IETHWrapper {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /* ========== CONSTANTS ============== */
    
    /* ========== ENCODED NAMES ========== */

    bytes32 internal constant sUSD = "sUSD";
    bytes32 internal constant sETH = "sETH";
    bytes32 internal constant ETH = "ETH";
    bytes32 internal constant SNX = "SNX";

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */
    bytes32 private constant CONTRACT_SYNTHETIX = "Synthetix";
    bytes32 private constant CONTRACT_SYSTEMSTATUS = "SystemStatus";
    bytes32 private constant CONTRACT_SYNTHSETH = "SynthsETH";
    bytes32 private constant CONTRACT_SYNTHSUSD = "SynthsUSD";
    bytes32 private constant CONTRACT_ISSUER = "Issuer";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_FEEPOOL = "FeePool";

    // ========== STATE VARIABLES ==========
    IWETH public weth;
    
    constructor(address _owner, address _resolver, address payable _WETH) 
        public 
        Owned(_owner) MixinSystemSettings(_resolver)
    {
        weth = IWETH(_WETH);
    }

    /* ========== VIEWS ========== */
    function resolverAddressesRequired() public view returns (bytes32[] memory addresses) {
        bytes32[] memory existingAddresses = MixinSystemSettings.resolverAddressesRequired();
        bytes32[] memory newAddresses = new bytes32[](6);
        newAddresses[0] = CONTRACT_SYSTEMSTATUS;
        newAddresses[1] = CONTRACT_SYNTHSETH;
        newAddresses[2] = CONTRACT_SYNTHSUSD;
        newAddresses[3] = CONTRACT_EXRATES;
        newAddresses[4] = CONTRACT_ISSUER;
        newAddresses[5] = CONTRACT_FEEPOOL;
        addresses = combineArrays(existingAddresses, newAddresses);
        return addresses;
    }

    /* ========== INTERNAL VIEWS ========== */

    function systemStatus() internal view returns (ISystemStatus) {
        return ISystemStatus(requireAndGetAddress(CONTRACT_SYSTEMSTATUS));
    }

    function synthsUSD() internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(CONTRACT_SYNTHSUSD));
    }

    function synthsETH() internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(CONTRACT_SYNTHSETH));
    }

    function feePool() internal view returns (IFeePool) {
        return IFeePool(requireAndGetAddress(CONTRACT_FEEPOOL));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXRATES));
    }

    function issuer() internal view returns (IIssuer) {
        return IIssuer(requireAndGetAddress(CONTRACT_ISSUER));
    }

    /* ========== PUBLIC FUNCTIONS ========== */


    // ========== VIEWS ==========

    function capacity() public view returns (uint _capacity) {
        // capacity = min(maxETH, maxETH - balance(1 - mintFeeRate))
        // uint balance = getBalance().multiplyDecimal(SafeDecimalMath.unit().add(mintFeeRate));
        // TODO: the capacity of the contract is exclusive of the mint fees?
        uint balance = getBalance();
        if(balance >= maxETH()) {
            return 0;
        }
        return maxETH().sub(balance);
    }

    function getBalance() public view returns (uint) {
        return weth.balanceOf(address(this));
    }

    function calculateMintFee(uint amount) public view returns (uint) {
        return amount.multiplyDecimalRound(mintFeeRate());
    }

    function calculateBurnFee(uint amount) public view returns (uint) {
        return amount.multiplyDecimalRound(burnFeeRate());
    }

    function maxETH() public view returns (uint256) {
        return getETHWrapperMaxETH();
    }

    function mintFeeRate() public view returns (uint256) {
        return getETHWrapperMintFeeRate();
    }

    function burnFeeRate() public view returns (uint256) {
        return getETHWrapperBurnFeeRate();
    }
    
    /* ========== MUTATIVE FUNCTIONS ========== */
    
    function mint(uint amount) external payable {
        require(amount <= weth.allowance(msg.sender, address(this)), "Allowance not high enough");
        require(amount <= weth.balanceOf(msg.sender), "Balance is too low");

        uint currentCapacity = capacity();
        require(currentCapacity > 0, "Contract has no spare capacity to mint");
        
        if(amount >= currentCapacity) {
            _mint(currentCapacity);
            // Refund is not needed, as we transfer the exact amount of WETH.
        } else {
            _mint(amount);
        }
    }

    // Burn `amount` sETH for `amount - fees` ETH.
    function burn(uint amount) external {
        uint reserves = getBalance();
        require(reserves > 0, "Contract cannot burn sETH for ETH, ETH balance is zero");
        
        if(amount >= reserves) {
            _burn(reserves);
            // Refund is not needed, as we transfer the exact amount of reserves.
        } else {
            _burn(amount);
        }
    }

    // ========== RESTRICTED ==========

    /**
     * @notice Fallback function
     */
    function() external payable {
        revert("Fallback disabled, use mint()");
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _mint(uint depositAmountEth) internal {
        weth.transferFrom(msg.sender, address(this), depositAmountEth);

        // Calculate minting fee.
        uint feeAmountEth = calculateMintFee(depositAmountEth);

        // Fee Distribution. Mints sUSD internally.
        // Normalize fee to sUSD
        uint feeSusd = exchangeRates().effectiveValue(ETH, feeAmountEth, sUSD);

        // Remit the fee in sUSDs
        issuer().synths(sUSD).issue(feePool().FEE_ADDRESS(), feeSusd);
        // TODO(liamz): Yo this feels a bit weird, burning the WETH.
        // Shouldn't we send it somewhere, else we're just inflating the sETH supply?
        weth.transfer(address(0), feeAmountEth);

        // Tell the fee pool about this
        feePool().recordFeePaid(feeSusd);

        // Finally, issue sETH.
        synthsETH().issue(msg.sender, depositAmountEth.sub(feeAmountEth));
    }

    function _burn(uint amount) internal {
        require(amount <= IERC20(address(synthsETH())).allowance(msg.sender, address(this)), "Allowance not high enough");
        require(amount <= IERC20(address(synthsETH())).balanceOf(msg.sender), "Balance is too low");

        // Burn the full amount sent.
        synthsETH().burn(msg.sender, amount);

        // Calculate burning fee.
        uint feeAmountEth = calculateBurnFee(amount);

        // Fee Distribution. Mints sUSD internally.
        // Normalize fee to sUSD
        uint feeSusd = exchangeRates().effectiveValue(ETH, feeAmountEth, sUSD);

        // Remit the fee in sUSDs
        issuer().synths(sUSD).issue(feePool().FEE_ADDRESS(), feeSusd);
        weth.transfer(address(0), feeAmountEth);

        // Tell the fee pool about this
        feePool().recordFeePaid(feeSusd);        

        // Finally, transfer ETH to the user, less the fee.
        weth.transfer(msg.sender, amount.sub(feeAmountEth));
    }

}
