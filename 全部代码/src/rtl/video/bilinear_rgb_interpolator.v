`timescale 1ns/1ps
// Q8双线性RGB；共享注册乘法器，保留水平小数，最后只舍入一次。
module bilinear_rgb_interpolator #(
    parameter integer LATCH_INPUTS=1
)(
    input wire clk,rst,abort,
    input wire in_valid,
    output wire in_ready,
    input wire [23:0] p00,p10,p01,p11,
    input wire [7:0] fraction_x,fraction_y,
    output wire out_valid,
    input wire out_ready,
    output reg [23:0] out_rgb
);
    localparam IDLE=0,TOP_SET=1,TOP_WAIT=2,TOP_USE=3,BOTTOM_WAIT=4,
        BOTTOM_USE=5,VERTICAL_WAIT=6,VERTICAL_USE=7,OUTPUT=8;
    reg [3:0] state;
    wire [23:0] a,b,c,d;
    wire [7:0] fx,fy;
    reg [1:0] channel;
    reg [15:0] horizontal_top;
    reg signed [17:0] multiply_a;
    reg signed [8:0] multiply_b;
    reg signed [26:0] product;
    wire [7:0] a_channel=a[channel*8+:8],c_channel=c[channel*8+:8];
    wire [7:0] b_channel,d_channel;
    wire signed [26:0] top_value=$signed({11'd0,a_channel,8'd0})+product;
    wire signed [26:0] bottom_value=$signed({11'd0,c_channel,8'd0})+product;
    wire signed [26:0] rounded_value=$signed({3'd0,horizontal_top,8'd0})+product+27'sd32768;
    assign in_ready=state==IDLE && !rst && !abort;
    assign out_valid=state==OUTPUT && !rst && !abort;
    generate if(LATCH_INPUTS)begin:sampled_inputs
        reg [23:0] saved_a,saved_b,saved_c,saved_d;
        reg [7:0] saved_fx,saved_fy;
        always @(posedge clk or posedge rst)begin
            if(rst)begin saved_a<=0;saved_b<=0;saved_c<=0;saved_d<=0;saved_fx<=0;saved_fy<=0;end
            else if(in_valid && in_ready)begin
                saved_a<=p00;saved_b<=p10;saved_c<=p01;saved_d<=p11;saved_fx<=fraction_x;saved_fy<=fraction_y;
            end
        end
        assign a=saved_a,b=saved_b,c=saved_c,d=saved_d,fx=saved_fx,fy=saved_fy;
        assign b_channel=b[channel*8+:8],d_channel=d[channel*8+:8];
    end else begin:held_inputs
        // 调用方保持全部输入至输出握手或取消；frame缓存已满足该所有权约定。
        assign a=p00,b=p10,c=p01,d=p11,fx=fraction_x,fy=fraction_y;
        reg [7:0] right_top,right_bottom;
        // 用接受沿及上一通道结果沿预取，隔开RAM输出与差值/DSP，不增加计算拍。
        always @(posedge clk or posedge rst)begin
            if(rst)begin right_top<=0;right_bottom<=0;end
            else if(!abort)begin
                if(in_valid && in_ready)begin right_top<=p10[7:0];right_bottom<=p11[7:0];end
                else if(state==VERTICAL_USE && channel!=2)begin
                    right_top<=channel==0?p10[15:8]:p10[23:16];
                    right_bottom<=channel==0?p11[15:8]:p11[23:16];
                end
            end
        end
        assign b_channel=right_top,d_channel=right_bottom;
    end endgenerate
    always @(posedge clk)product<=multiply_a*multiply_b;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;channel<=0;
            horizontal_top<=0;multiply_a<=0;multiply_b<=0;out_rgb<=0;
        end else if(abort)begin state<=IDLE;channel<=0;out_rgb<=0;end
        else case(state)
            IDLE:if(in_valid)begin
                channel<=0;state<=TOP_SET;
            end
            TOP_SET:begin
                multiply_a<=$signed({1'b0,b_channel})-$signed({1'b0,a_channel});
                multiply_b<=$signed({1'b0,fx});state<=TOP_WAIT;
            end
            TOP_WAIT:state<=TOP_USE;
            TOP_USE:begin
                horizontal_top<=top_value[15:0];
                multiply_a<=$signed({1'b0,d_channel})-$signed({1'b0,c_channel});
                multiply_b<=$signed({1'b0,fx});state<=BOTTOM_WAIT;
            end
            BOTTOM_WAIT:state<=BOTTOM_USE;
            BOTTOM_USE:begin
                multiply_a<=bottom_value-$signed({11'd0,horizontal_top});
                multiply_b<=$signed({1'b0,fy});state<=VERTICAL_WAIT;
            end
            VERTICAL_WAIT:state<=VERTICAL_USE;
            VERTICAL_USE:begin
                out_rgb[channel*8+:8]<=rounded_value[23:16];
                if(channel==2)state<=OUTPUT;
                else begin channel<=channel+1'b1;state<=TOP_SET;end
            end
            OUTPUT:if(out_ready)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
endmodule
