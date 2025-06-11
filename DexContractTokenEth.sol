// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract DexContractTokenETH {
    IERC20 public token;
    IWETH public WETH;

    uint256 public reserveToken;
    uint256 public reserveETH;

    uint256 public totalLiquidity;
    mapping(address => uint256) public liquidity;

    uint256 public constant FEE_PERCENT = 5;
    uint256 public constant FEE_DENOMINATOR = 1000;

    event LiquidityAdded(address indexed provider, uint256 tokenAmount, uint256 ethAmount, uint256 liquidityMinted);
    event LiquidityRemoved(address indexed provider, uint256 tokenAmount, uint256 ethAmount, uint256 liquidityBurned);
    event Swap(address indexed swapper, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);

    constructor(address _token, address _weth) {
        token = IERC20(_token);
        WETH = IWETH(_weth);
    }

    function addLiquidity(uint256 tokenAmount) external payable returns (uint256 liquidityMinted) {
        require(tokenAmount > 0 && msg.value > 0, "Amounts must be > 0");
        require(token.transferFrom(msg.sender, address(this), tokenAmount), "Transfer failed");

        if (totalLiquidity == 0) {
            liquidityMinted = sqrt(tokenAmount * msg.value);
        } else {
            liquidityMinted = min(
                (tokenAmount * totalLiquidity) / reserveToken,
                (msg.value * totalLiquidity) / reserveETH
            );
        }

        require(liquidityMinted > 0, "Insufficient liquidity minted");
        liquidity[msg.sender] += liquidityMinted;
        totalLiquidity += liquidityMinted;

        _updateReserves();

        emit LiquidityAdded(msg.sender, tokenAmount, msg.value, liquidityMinted);
    }

    function removeLiquidity(uint256 liquidityAmount) external returns (uint256 tokenOut, uint256 ethOut) {
        require(liquidity[msg.sender] >= liquidityAmount, "Not enough liquidity");

        tokenOut = (liquidityAmount * reserveToken) / totalLiquidity;
        ethOut = (liquidityAmount * reserveETH) / totalLiquidity;

        liquidity[msg.sender] -= liquidityAmount;
        totalLiquidity -= liquidityAmount;

        require(token.transfer(msg.sender, tokenOut), "Transfer failed");
        payable(msg.sender).transfer(ethOut);

        _updateReserves();

        emit LiquidityRemoved(msg.sender, tokenOut, ethOut, liquidityAmount);
    }

    function swapExactETHForToken(uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        require(msg.value > 0, "Must send ETH");

        uint256 amountInWithFee = msg.value * (FEE_DENOMINATOR - FEE_PERCENT) / FEE_DENOMINATOR;
        tokensOut = (amountInWithFee * reserveToken) / (reserveETH + amountInWithFee);
        require(tokensOut >= minTokensOut, "Insufficient output");

        require(token.transfer(msg.sender, tokensOut), "Transfer failed");

        _updateReserves();

        emit Swap(msg.sender, address(0), msg.value, address(token), tokensOut);
    }

    function swapExactTokenForETH(uint256 tokenIn, uint256 minETHOut) external returns (uint256 ethOut) {
        require(tokenIn > 0, "AmountIn > 0");
        require(token.transferFrom(msg.sender, address(this), tokenIn), "Transfer failed");

        uint256 amountInWithFee = tokenIn * (FEE_DENOMINATOR - FEE_PERCENT) / FEE_DENOMINATOR;
        ethOut = (amountInWithFee * reserveETH) / (reserveToken + amountInWithFee);
        require(ethOut >= minETHOut, "Insufficient output");

        payable(msg.sender).transfer(ethOut);

        _updateReserves();

        emit Swap(msg.sender, address(token), tokenIn, address(0), ethOut);
    }

    function _updateReserves() internal {
        reserveToken = token.balanceOf(address(this));
        reserveETH = address(this).balance;
    }

    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint x, uint y) internal pure returns (uint) {
        return x < y ? x : y;
    }

    receive() external payable {}
}
