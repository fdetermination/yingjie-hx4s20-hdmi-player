`timescale 1ns/1ps
// 32拍无符号恢复除法，仅用于每图/每行几何配置，不进入视频逐像素路径。
module unsigned_divider(
    input wire clk,rst,abort,start,
    input wire [31:0] dividend,divisor,
    output reg busy,done,error,
    output reg [31:0] quotient,remainder
);
    reg [31:0] numerator,denominator,result;
    reg [32:0] rem;
    reg [5:0] bits_left;
    wire [32:0] shifted={rem[31:0],numerator[31]};
    wire subtract=shifted>={1'b0,denominator};
    wire [32:0] next_rem=subtract?shifted-{1'b0,denominator}:shifted;
    wire [31:0] next_result={result[30:0],subtract};
    always @(posedge clk or posedge rst)begin
        if(rst)begin busy<=0;done<=0;error<=0;quotient<=0;remainder<=0;
            numerator<=0;denominator<=0;result<=0;rem<=0;bits_left<=0;end
        else if(abort)begin busy<=0;done<=0;error<=0;end
        else begin
            done<=0;
            if(start && !busy)begin
                error<=divisor==0;
                if(divisor==0)begin done<=1;quotient<=0;remainder<=dividend;end
                else begin numerator<=dividend;denominator<=divisor;result<=0;rem<=0;bits_left<=32;busy<=1;end
            end else if(busy)begin
                numerator<=numerator<<1;rem<=next_rem;result<=next_result;bits_left<=bits_left-1'b1;
                if(bits_left==1)begin quotient<=next_result;remainder<=next_rem[31:0];busy<=0;done<=1;end
            end
        end
    end
endmodule
