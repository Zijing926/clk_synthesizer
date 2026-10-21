`timescale 1ns / 1ps

/*
 * @module por_reset  power_on_reset
 * @brief 上电自动复位模块（无外部RST键时使用）
 * @param POR_DELAY_CNT 复位延时计数，默认100ms@125MHz (12_500_000)
 */
 
module por_reset #(
    parameter POR_DELAY_CNT = 24'd12_500_000
)(
    input  logic clk,        // 系统时钟
    output logic rst  // 复位有效信号，高有效
);

logic [23:0] por_cnt = 0;

always_ff @(posedge clk) begin
    if (por_cnt < POR_DELAY_CNT) begin
        por_cnt   <= por_cnt + 1'b1;
        rst <= 1'b1;  // 复位有效
    end else begin
        rst <= 1'b0;  // 复位释放
    end
end

endmodule