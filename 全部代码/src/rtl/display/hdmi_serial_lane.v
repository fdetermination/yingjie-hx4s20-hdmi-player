`timescale 1ns/1ps
// 一路TMDS从10bit符号到真实ODDR输出；code的像素/5倍时钟相位由最终PLL负责。
module hdmi_serial_lane(input wire serial_clk,rst,input wire [9:0] code,output wire pad);
    wire rise_bit,fall_bit;
    hdmi_tmds_serializer serializer(.serial_clk(serial_clk),.rst(rst),.code(code),.rise_bit(rise_bit),.fall_bit(fall_bit));
    hdmi_tmds_ddr_output output_register(.serial_clk(serial_clk),.rst(rst),.rise_bit(rise_bit),.fall_bit(fall_bit),.pad(pad));
endmodule
