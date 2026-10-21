`timescale 1ns / 1ps

/**
 * @module ad9517_config
 * @brief AD9517-3 自动配置 FSM,按最终确认的配置表顺序写 32 个寄存器
 * @note Carry out the module after cfg_start=1. cfg_done=1 after the execution.
 */
module ad9517_config (
    input  logic        clk,            // system clock 125MHz
    input  logic        rst,            // reset
    input  logic        cfg_start,      // start pulse of configuration (power-up or VIO)
    input  logic        spi_done,       // done-signal from spi_master

    output logic        spi_start,      // 输出给 spi_master 的启动脉冲
    output logic [23:0] spi_data_tx,    // 输出给 spi_master 的 24 位数据
    output logic        cfg_done        // configuration done
);

    // clk = 125MHz
    parameter CLK_FREQ = 125_000_000;
    parameter DELAY_1MS = CLK_FREQ / 1000;     // 1ms
    parameter DELAY_5MS = 5 * DELAY_1MS;       // 5ms

    // ============ state define ============
    typedef enum logic [3:0] {
        IDLE        = 4'd0,
        WRITE_REG   = 4'd1,   // 发起一次 SPI 写
        WAIT_SPI    = 4'd2,   // wait for SPI finished
        WAIT_1MS    = 4'd3,   // Update 后等 1ms
        DONE        = 4'd5
    } state_t;

    state_t state;
    logic [4:0]  reg_idx;     // 0~31, 32 steps in total
    logic [31:0] delay_cnt;

    // ============ 24bit cfg table ============
    logic [23:0] reg_table [0:31];	//[23:0] is the length of every element. 32 elements in total 

    always @(posedge clk) begin
        if (rst) begin
            reg_table[0]  <= 24'h00107c;	// 0x010 = 0x7c	PLL on
            reg_table[1]  <= 24'h001101;	// 0x011 = 0x01 R_low
            reg_table[2]  <= 24'h001200;	// 0x012 = 0x00 R_high
            reg_table[3]  <= 24'h001404;	// 0x014 = 0x04 B_low
            reg_table[4]  <= 24'h001500;	// 0x015 = 0x00 B_high
            reg_table[5]  <= 24'h001604;	// 0x016 = 0x04 Prescaler P:Divide-by-8(8/9 mode) DM mode.
            reg_table[6]  <= 24'h0017b5;	// 0x017 = 0xb5 Antibacklash Pulse Width: 1.3
            reg_table[7]  <= 24'h001806;	// 0x018 = 0x06	Reset VCO calibration
            reg_table[8]  <= 24'h001c07;	// 0x01c = 0x07	REF: differential, power-on
            reg_table[9]  <= 24'h023201;	// 0x232 = 0x01 refresh register #1
            reg_table[10] <= 24'h01e000;	// 0x1e0 = 0x00	VCO  = ÷2
            reg_table[11] <= 24'h01e102;	// 0x1e1 = 0x02	channel source = VCO divider output
            reg_table[12] <= 24'h019180;	// 0x191 = 0x80	Divider0: 1 (bypass)
            reg_table[13] <= 24'h019200;	// 0x192 = 0x00	Divider0 to OUT0 and OUT1
            reg_table[14] <= 24'h019780;	// 0x197 = 0x80	Divider1: 1 (bypass)
            reg_table[15] <= 24'h019800;	// 0x198 = 0x00	Divider1 to OUT2 and OUT3
            reg_table[16] <= 24'h019900;	// 0x199 = 0x00 Channel Divider 2.1
            reg_table[17] <= 24'h019b00;	// 0x19b = 0x00 Divider 2.2=2(will bypass)
            reg_table[18] <= 24'h019c20;	// 0x19c = 0x20	bypass Divider 2.2
            reg_table[19] <= 24'h019e33;	// 0x19e = 0x33 Channel Divider 3.1
            reg_table[20] <= 24'h01a000;	// 0x1a0 = 0x00 Channel Divider 3.2
            reg_table[21] <= 24'h01a128;	// 0x1a1 = 0x28 Bypass Channel Dividers 3.2
            reg_table[22] <= 24'h00f000;	// 0x0f0 = 0x00 Out0: LVPECL 400mV, power-on
            reg_table[23] <= 24'h00f100;	// 0x0f1 = 0x00 Out1: LVPECL 400mV, power-on
            reg_table[24] <= 24'h00f400;	// 0x0f4 = 0x00 Out2: LVPECL 400mV, power-on
            reg_table[25] <= 24'h00f500;	// 0x0f5 = 0x00 Out3: LVPECL 400mV, power-on
            reg_table[26] <= 24'h014042;	// 0x140 = 0x42 Out4: LVDS, power-on
            reg_table[27] <= 24'h014142;	// 0x141 = 0x42 Out5: LVDS, power-on
            reg_table[28] <= 24'h014242;	// 0x142 = 0x42 Out6: LVDS, power-on
            reg_table[29] <= 24'h014342;	// 0x143 = 0x42 Out7: LVDS, power-on
            reg_table[30] <= 24'h001807;	// 0x018 = 0x07 Initiate VCO calibration
            reg_table[31] <= 24'h023201;	// 0x232 = 0x01 refresh register #2
        end
    end

    // ============ state machine ============
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= IDLE;
            reg_idx    <= 5'd0;
            spi_start  <= 1'b0;
            spi_data_tx <= 24'h0;
            delay_cnt  <= 32'd0;
            cfg_done   <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    cfg_done <= 1'b0;
                    reg_idx  <= 5'd0;
                    spi_start <= 1'b0;
                    if (cfg_start) begin
                        state <= WRITE_REG;
                    end
                end

                WRITE_REG: begin
                    spi_data_tx <= reg_table[reg_idx];  // 直接 24bit 扔出去
                    spi_start   <= 1'b1;
                    state       <= WAIT_SPI;
                end

                WAIT_SPI: begin
                    spi_start <= 1'b0;
                    if (spi_done) begin
                        state <= WAIT_1MS;
                        delay_cnt <= DELAY_1MS;
                    end
                end

                WAIT_1MS: begin
                    if (delay_cnt == 0) begin
                        if (reg_idx == 31)
                            state <= DONE;
                        else begin
                            reg_idx <= reg_idx + 5'd1;
                            state  <= WRITE_REG;
                        end
                    end else begin
                        delay_cnt <= delay_cnt - 32'd1;
                    end
                end

                DONE: begin
                    cfg_done <= 1'b1;// 保持，直到复位或重新 cfg_start
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule