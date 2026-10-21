`timescale 1ns / 1ps
//Write data bits are registered on the rising edge of this clock -> FPGA refresh mosi on the previous falling edge
//Read data bits are registered on the falling edge ->AD9517 refresh miso on the falling edge -> FPGA register miso on the next rising edge
/**
 * @module spi_master
 * @brief AD9517-3 专用 SPI Master（固定 24 位 = 3 字节）
 * @note 写：上升沿采样 MOSI（AD9517 手册 Page 38）
 *       读：下降沿更新 MISO，FPGA 在上升沿采样（留出建立时间）
 */
module spi_master(
    input  logic       	clk,		//system clock 125MHz
    input  logic       	rst,		//high active
    input  logic       	start,		//start to transfer data
	
    input  logic [23:0] data_tx,	//16-bit instruction word to ADS8028 + 8-bit 
    output logic [7:0]  data_rx,	//8-bit data read back from ADS8028
    output logic       	sclk,		//SPI clock
    output logic       	csb,		//channel select(low active)
	
	input  logic 		miso,		//MISO
    output logic       	mosi,		//MOSI
    output logic       	sdio_oe,	//SDIO output enable: 1 = MOSI, 0 = MISO
    output logic       	done,	
	input  logic 		cpol		//CPOL
);

	//10MHz SCLK Generation (125MHz/12 = 10.4167MHz)
	logic [3:0] sclk_div_cnt; 	//0~11:  12 periods of 125MHz = 1 period of SCLK 
	logic sclk_en;
	always_ff @(posedge clk or posedge rst) begin
		if (rst) begin
			sclk_div_cnt <= 4'd0;
			sclk <= cpol;			
		end else if (sclk_en) begin
			if (sclk_div_cnt == 4'd11) begin
				sclk_div_cnt <= 4'd0;
				sclk <= ~sclk;
			end else
				sclk_div_cnt <= sclk_div_cnt + 1;
		end else begin
			sclk_div_cnt <= 4'd0;
			sclk <= cpol;
		end
	end
	
	//SCLK edge detect
	logic sclk_dly1, sclk_dly2;
	logic sclk_fall;
	logic sclk_rise;
	always_ff @(posedge clk or posedge rst) begin
		if (rst) begin
			sclk_dly1 <= 1'b1;
			sclk_dly2 <= 1'b1;
		end else begin
			sclk_dly1 <= sclk;
			sclk_dly2 <= sclk_dly1;
		end
	end
	assign sclk_fall = sclk_dly2 & ~sclk_dly1;	//falling edge
	assign sclk_rise = ~sclk_dly2 & sclk_dly1;	//rising edge
	
    logic [4:0] 	bit_cnt;			//0~23 (24 bits total)
    logic [23:0] 	tx_shift_reg;       // transmit shift register
    logic [7:0] 	rx_shift_reg;       // receive shift register
	logic 			is_read;			// 1 = read; 0 = write
	
    logic [1:0]  	wait_cnt;    		// CS setup time counter	CS to SCLK Setup and Hold, tS > 2ns
	localparam WAIT_CYCLES = 2'd2;		// ~16ns @ 125 MHz → > t_S (2 ns)
	//SPI transfer state machine
    enum {IDLE, WAIT_TS, TRANSFER, WAIT_TC, DONE} state;
	
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state        <= IDLE;
            csb          <= 1'b1;
            mosi         <= 1'b0;
            sdio_oe      <= 1'b0;
            done         <= 1'b0;
            data_rx      <= 8'h0;
            tx_shift_reg <= 24'h0;
            rx_shift_reg <= 8'h0;
            bit_cnt      <= 5'd0;
            sclk_en      <= 1'b0;
            is_read      <= 1'b0;
			wait_cnt 	 <= 2'd0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    csb <= 1'b1;
                    sdio_oe <= 1'b0;
                    sclk_en <= 1'b0;
                    if (start) begin
                        tx_shift_reg <= data_tx;
                        is_read      <= data_tx[23];  	// MSB 是 R/W 位
                        bit_cnt      <= 5'd23;        	// 24 bits to go
                        csb          <= 1'b0;			// assert CS#
                        sdio_oe      <= 1'b1;         	// 前 16 位一定驱动
                        mosi         <= data_tx[23];  	// 第一个 bit 提前放上
						wait_cnt 	 <= 2'd0;
                        state        <= WAIT_TS;
                    end
                end
				
				//Wait t_S (≥2 ns) after CS# falls before first SCLK edge. t_S: Setup time between CS falling edge and SCLK rising edge (start of communication cycle)
				WAIT_TS: begin
                    if (wait_cnt < WAIT_CYCLES) begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end else begin
                        sclk_en <= 1'b1;              // start SCLK toggling
                        state   <= TRANSFER;
						wait_cnt <= 2'd0;
                    end
				end
				
                TRANSFER: begin
                    // ---- rising edge: sample MISO + shift  ----
                    if (sclk_rise) begin
                        // shift（为下一次下降沿更新 MOSI 准备）
                        tx_shift_reg <= {tx_shift_reg[22:0], 1'b0};
						
                        // 三态切换：第 16 位（bit_cnt==8）采样完后，如果是读操作，释放总线
                        if (bit_cnt == 8 && is_read) begin
                            sdio_oe <= 1'b0;
                        end
						
                        // 采样 MISO（AD9517 在下降沿更新，上升沿采样建立时间充裕）
                        // 只读后 8 位（bit_cnt 从 7 到 0 期间）
                        if (is_read && bit_cnt < 8)
                            rx_shift_reg <= {rx_shift_reg[6:0], miso};
                        if (bit_cnt == 0) begin
                            state <= WAIT_TC;
                        end else
                            bit_cnt <= bit_cnt - 1'b1;
                    end
                                   
				// ---- falling edge: refresh MOSI ----
                    if (sclk_fall) begin
                        mosi <= tx_shift_reg[23];  // next bit（提前放到线上）
                    end
				end 
				
				//Wait t_C (≥2 ns) after CS# falls before first SCLK edge. t_C: Setup time between SCLK rising edge and CS rising edge (end of communication cycle)
				WAIT_TC:begin
                    if (wait_cnt < WAIT_CYCLES) begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end else begin
						sclk_en <= 1'b0;		// end SCLK toggling          
                        state   <= DONE;
                    end
				end
				
                DONE: begin
                    data_rx <= rx_shift_reg;
                    csb     <= 1'b1;
                    sdio_oe <= 1'b0;
                    done    <= 1'b1;
                    sclk_en <= 1'b0;
                    state   <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
 