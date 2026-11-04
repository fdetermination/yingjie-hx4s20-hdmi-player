`timescale 1ns/1ps
// 5x串行时钟的DDR数据准备：每个serial_clk周期提供上升/下降沿两个TMDS bit。
// code在pixel_clk域保持一个完整像素周期；最终pad由器件ODDR吸收rise_bit/fall_bit。
module hdmi_tmds_serializer(
    input wire serial_clk,rst,
    input wire [9:0] code,
    output reg rise_bit,fall_bit,
    output reg [2:0] bit_phase
);
    reg [9:0] shift;
    always @(posedge serial_clk or posedge rst)begin
        if(rst)begin shift<=0;rise_bit<=0;fall_bit<=0;bit_phase<=0;end
        else if(bit_phase==0)begin
            rise_bit<=code[0];fall_bit<=code[1];shift<={2'b0,code[9:2]};bit_phase<=1;
        end else begin
            rise_bit<=shift[0];fall_bit<=shift[1];shift<={2'b0,shift[9:2]};
            if(bit_phase==4)bit_phase<=0;else bit_phase<=bit_phase+1'b1;
        end
    end
endmodule

// 供应商ODDR隔离层。仿真时可用tb直接观察rise_bit/fall_bit。
module hdmi_tmds_ddr_output(
    input wire serial_clk,rst,rise_bit,fall_bit,
    output wire pad
);
    EG_LOGIC_ODDR #(.ASYNCRST("ENABLE")) ddr(.q(pad),.clk(serial_clk),.d0(rise_bit),.d1(fall_bit),.rst(rst));
endmodule
