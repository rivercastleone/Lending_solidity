// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";
interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function setPrice(address token, uint256 price) external;
}

contract DreamAcademyLending {
    IPriceOracle public oracle;
    IERC20 public usdc;
    uint total; 
    
    struct Lending {
        uint amount;
        uint bnum;
    }
    
    mapping(address => uint)  depositUSDC;
    mapping(address => Lending)  LendingBalance;
    mapping(address => Lending)  depositETH; // 담보로 맡긴 Ether
    uint256 day_rate = 1.001 ether; // 이자율 0.1% (복리)
    uint block_per_rate = 1.0000000139 ether;  // 하루 이자율이 0.1% 일때 한 블록당 이자율 0.0000000139%
                                    
    constructor(IPriceOracle target_oracle, address usdcAddress) {
        oracle = target_oracle;
        usdc = IERC20(usdcAddress);
    }
   function calc(uint principal, uint periods,uint rate) internal returns (uint result) {
        uint p = principal;
        for (uint i = 0; i < periods; i++) {
            p = (p * rate) / 1 ether;
        }
        result = p - principal;
    }

    function interest(address user) internal {
        uint gap = (block.number - LendingBalance[user].bnum)*12;  // 블록을 시간으로 초 단위로 변환
        console.log("current gap time", gap);
        if(gap>0){
            if(gap == 12){ // 12초 이자율 계산
                uint calcInterest = calc(LendingBalance[user].amount, gap, block_per_rate);
                LendingBalance[user].amount += calcInterest;
                }
            else {
                uint calcInterest = calc(LendingBalance[user].amount, gap, day_rate);
                LendingBalance[user].amount += calcInterest;
            }
        }
    }


    function getOracle() internal view returns (uint etherPrice, uint usdcPrice) {  
        etherPrice = oracle.getPrice(address(0x0));
        usdcPrice = oracle.getPrice(address(usdc));
    }

    function initializeLendingProtocol(address addr) external payable {
        usdc = IERC20(addr);
        usdc.transferFrom(msg.sender, address(this), msg.value);
    }

    function deposit(address token, uint256 amount) public payable {
        if (token == address(0x0)) { 
            require(msg.value == amount, "Invalid ETH amount");
            depositETH[msg.sender].amount += msg.value; // Ether를 담보로 예치
            depositETH[msg.sender].bnum = block.number; 
        } else {
            require(amount > 0, "Invalid usdc amount");
            depositUSDC[msg.sender] += amount;
            total += amount;
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }
    }

    function borrow(address token, uint amount) public {
        interest(msg.sender);
        (uint etherPrice, uint usdcPrice) = getOracle();

        uint collateralusdc = depositETH[msg.sender].amount * etherPrice / usdcPrice / 2 ;
        uint price = (LendingBalance[msg.sender].amount + amount) ;

        require(collateralusdc >= price, "Insufficient collateral");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient amount");

        LendingBalance[msg.sender].bnum = block.number;
        LendingBalance[msg.sender].amount += amount;
        IERC20(token).transfer(msg.sender, amount);
    }

    function repay(address token, uint amount) public {
        interest(msg.sender);
        require(LendingBalance[msg.sender].amount >= amount, "Insufficient supply");

        LendingBalance[msg.sender].amount -= amount;
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(address token, uint amount) public {
        interest(msg.sender);
        (uint etherPrice, uint usdcPrice) = getOracle();

        if (token == address(0x0)) { 
            require(depositETH[msg.sender].amount >= amount, "Insufficient ETH");

            uint collateral = (depositETH[msg.sender].amount - amount) * etherPrice / 1 ether;
            uint value = LendingBalance[msg.sender].amount * usdcPrice / etherPrice;

            // LTV 75% 이하 유지
            require(collateral * 100 >= value * 75, "Insufficient collateral");

            depositETH[msg.sender].amount -= amount;
            msg.sender.call{value: amount}("");

        } else { 
            require(depositUSDC[msg.sender] >= amount, "Insufficient usdc");
            // 덜 구현함...
            depositUSDC[msg.sender] -= amount;
            IERC20(token).transfer(msg.sender, amount);
        }
    }

    function liquidate(address borrower, address token, uint amount) public {
        interest(borrower);
        (uint etherPrice, uint usdcPrice) = getOracle();

        uint debt = LendingBalance[borrower].amount * usdcPrice / etherPrice;
        uint collateral = depositETH[borrower].amount;
        uint maxliquidate = LendingBalance[borrower].amount / 4;

        require(debt > collateral * 3 / 4); 
        require(amount <= maxliquidate); //청산은 25% 까지만 가능

        depositETH[borrower].amount -= amount * usdcPrice / etherPrice;
        LendingBalance[borrower].amount -= amount;
        IERC20(token).transfer(msg.sender, amount);
    }

    function getAccruedSupplyAmount(address token) public view returns (uint price) {
        if (token == address(0x0)) {
            price = depositETH[msg.sender].amount;
        } else {
            price = depositUSDC[msg.sender];
        }
    }

    receive() external payable {
        total += msg.value;
    }
}
