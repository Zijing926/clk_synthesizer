`timescale 1ns / 1ps

/**
 * @module clk_synthesizer_top
 * @brief AD9517-3 配置顶层：自动配置 + VIO 手动读写并存
 */
module clk_synthesizer_top (
    // Differential clk innput(VCXO 125MHz)
    input  logic vcxo_out_p,
    input  logic vcxo_out_n,
    // AD9517 SPI interface
    output logic PLL_SCLK,
    output logic PLL_CSB,
    inout  wire  PLL_SDIO,
    output logic PLL_RESETB,
    // AD9517 other interface
    output logic PLL_REF_SEL,
    output logic PLL_PDB,
    input  logic PLL_STATUS,
    // reference clock
    output logic PLL_REFIN,
    output logic PLL_REFINB,
    // PLL clock input (AD9517 OUT6/OUT6B)
    input  logic PLL_OUT1,
    input  logic PLL_OUT1B,
    // PLL LD input
    input  logic PLL_LD,
    // LED 指示
    output logic [1:0] led
);

    // ========== internal signal ==========
    logic sys_clk_125m;
    logic por_rst;
    logic rst;

    // ---------- VIO signal ----------
    logic [23:0] manual_data_tx;	//probe_out0: 手动模式 SPI 数据
    logic        manual_start;		//manual Start button
    logic        vio_reset;
    logic        auto_cfg_boot_pending;
    logic        auto_cfg_boot_active;
	
    // ========== VIO edge detect ==========
    logic manual_start_dly;
	logic manual_start_pulse;
    always_ff @(posedge sys_clk_125m) begin
        manual_start_dly <= manual_start;
    end
    assign manual_start_pulse = manual_start && !manual_start_dly;  		// pulse of manual Start button

    // ---------- SPI signal ----------
    logic        spi_start;
    logic [7:0]  spi_data_rx;
    logic        spi_done;
    logic        spi_sdio_oe;
    logic        spi_mosi;
    logic        spi_miso;

    // ---------- 自动配置模块信号 ----------
    logic        auto_spi_start;
    logic [23:0] auto_spi_data_tx;
    logic        auto_cfg_done;

    always_ff @(posedge sys_clk_125m) begin
        if (rst) begin
            auto_cfg_boot_pending <= 1'b1;
            auto_cfg_boot_active  <= 1'b1;
        end else begin
            auto_cfg_boot_pending <= 1'b0;
            if (auto_cfg_done)
                auto_cfg_boot_active <= 1'b0;
        end
    end
    // ---------- SPI signal after multiplexer(MUX) ----------
    logic        spi_start_mux;
    logic [23:0] spi_data_tx_mux;
    assign spi_start_mux   = auto_cfg_boot_active ? auto_spi_start : manual_start_pulse;
    assign spi_data_tx_mux = auto_cfg_boot_active ? auto_spi_data_tx : manual_data_tx;
	
    // ========== AD9517 OUT6 differential input ==========
    logic pll_out1_single;

    IBUFDS #(
        .DIFF_TERM    ("TRUE"),
        .IBUF_LOW_PWR ("FALSE")
    ) ibufds_pll_out1 (
        .I  (PLL_OUT1),
        .IB (PLL_OUT1B),
        .O  (pll_out1_single)
    );

    // ========== power on reset ==========
    por_reset u_por_reset (
        .clk (sys_clk_125m),
        .rst (por_rst)
    );

    assign rst = por_rst || vio_reset;

    // ========== reference clock 62.5MHz ==========
    ref_clk_gen u_ref_clk_gen (
        .vcxo_out_p   (vcxo_out_p),
        .vcxo_out_n   (vcxo_out_n),
        .rst          (rst),
        .sys_clk_125m (sys_clk_125m),
        .PLL_REFIN    (PLL_REFIN),
        .PLL_REFINB   (PLL_REFINB)
    );


    // ========== SPI Master ==========
    spi_master u_spi_master (
        .clk        (sys_clk_125m),
        .rst        (rst),
        .start      (spi_start_mux),
        .data_tx    (spi_data_tx_mux),
        .data_rx    (spi_data_rx),
        .sclk       (PLL_SCLK),
        .csb        (PLL_CSB),
        .miso       (spi_miso),
        .mosi       (spi_mosi),
        .sdio_oe    (spi_sdio_oe),
        .done       (spi_done),
        .cpol       (1'b0)
    );

    // ========== 自动配置模块 ==========
    ad9517_config ad9517_config_inst (
        .clk        (sys_clk_125m),
        .rst        (rst),
        .cfg_start  (auto_cfg_boot_pending && !rst),
        .spi_done   (spi_done),
        .spi_start  (auto_spi_start),
        .spi_data_tx(auto_spi_data_tx),
        .cfg_done   (auto_cfg_done)
    );

    // ========== VIO ==========
    vio_0 u_vio (
        .clk        (sys_clk_125m),
        .probe_out0 (manual_data_tx),  	// [23:0] 手动模式数据
        .probe_out1 (manual_start),    	// [0]    手动模式 Start
        .probe_out2 (vio_reset),       	// [0]    手动复位
        .probe_in0  (spi_data_rx),     	// [7:0]  data read from AD9517
        .probe_in1  (PLL_LD),          	// [0]    Lock Detect
        .probe_in2  (PLL_STATUS),      	// [0]    PLL_STATUS
        .probe_in3  (spi_sdio_oe),     	// [0]    SDIO 方向
        .probe_in4  (auto_cfg_done)    	// [0]    自动配置完成
    );

    // ========== physical pin connection ==========
    assign PLL_SDIO   = spi_sdio_oe ? spi_mosi : 1'bz;
    assign spi_miso   = PLL_SDIO;
    assign PLL_RESETB = !vio_reset;
    assign PLL_REF_SEL = 1'b0;
    assign PLL_PDB     = 1'b1;

    // ========== LED ==========
    // LED[0] = 自动配置完成指示
    // LED[1] = PLL lock detection
    assign led[0]   = auto_cfg_done;
    assign led[1]   = PLL_LD;

    // ========== ILA ==========
    (* keep = "true", mark_debug = "true" *) logic [23:0] dbg_tx;
    (* keep = "true", mark_debug = "true" *) logic [7:0]  dbg_rx;
    (* keep = "true", mark_debug = "true" *) logic        dbg_done;
    (* keep = "true", mark_debug = "true" *) logic        dbg_csb;
    (* keep = "true", mark_debug = "true" *) logic        dbg_sclk;
    (* keep = "true", mark_debug = "true" *) logic        dbg_mosi;
    (* keep = "true", mark_debug = "true" *) logic        dbg_cfg_done;

    always_ff @(posedge sys_clk_125m) begin
        dbg_tx       <= spi_data_tx_mux;
        dbg_rx       <= spi_data_rx;
        dbg_done     <= spi_done;
        dbg_csb      <= PLL_CSB;
        dbg_sclk     <= PLL_SCLK;
        dbg_mosi     <= spi_mosi;
        dbg_cfg_done <= auto_cfg_done;
    end

    ila_0 u_ila (
        .clk   (sys_clk_125m),
        .probe0 (dbg_csb),
        .probe1 (dbg_sclk),
        .probe2 (PLL_SDIO),
        .probe3 (PLL_STATUS),
        .probe4 (dbg_tx),
        .probe5 (dbg_rx),
        .probe6 (dbg_done),
        .probe7 (dbg_cfg_done)
    );

endmodule