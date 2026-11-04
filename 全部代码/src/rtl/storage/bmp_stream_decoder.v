`timescale 1ns/1ps
// 自主 BMP 文件流解码器：24-bit BI_RGB、行填充、正负高度和输出背压。
module bmp_stream_decoder #(
    parameter integer MAX_WIDTH=1920, MAX_HEIGHT=1080
)(
    input wire clk,rst,start,abort,
    input wire [31:0] file_size,
    input wire in_valid,
    output wire in_ready,
    input wire [7:0] in_data,
    input wire in_last,
    output reg pixel_valid,
    input wire pixel_ready,
    output reg [23:0] pixel_rgb,
    output reg [15:0] pixel_x,pixel_y,width,height,
    output reg bottom_up,
    output reg header_valid,
    output wire busy,
    output reg done,error,
    output reg [3:0] error_code
);
    localparam IDLE=0,HEADER=1,CHECK=2,SKIP=3,PIXELS=4,PADDING=5,TAIL=6,FLUSH=7,FINISHED=8,FAILED=9,
        LAYOUT=10,PRODUCT=11,END_OFFSET=12,RANGE_CHECK=13,NORMALIZE=14;
    localparam WIDTH_LIMIT=(MAX_WIDTH<=0 || MAX_WIDTH>65535)?65535:MAX_WIDTH;
    localparam HEIGHT_LIMIT=(MAX_HEIGHT<=0 || MAX_HEIGHT>65535)?65535:MAX_HEIGHT;
    localparam WIDTH_BITS=(MAX_WIDTH<=0)?16:((WIDTH_LIMIT<2)?1:$clog2(WIDTH_LIMIT+1));
    localparam HEIGHT_BITS=(MAX_HEIGHT<=0)?16:((HEIGHT_LIMIT<2)?1:$clog2(HEIGHT_LIMIT+1));
    localparam X_BITS=(MAX_WIDTH<=0)?16:((WIDTH_LIMIT<2)?1:$clog2(WIDTH_LIMIT));
    localparam ROW_BITS=(MAX_HEIGHT<=0)?16:((HEIGHT_LIMIT<2)?1:$clog2(HEIGHT_LIMIT));
    localparam STRIDE_BITS=$clog2(((WIDTH_LIMIT*3+3)&32'hfffffffc)+1);
    localparam PRODUCT_BITS=STRIDE_BITS+HEIGHT_BITS;
    reg [3:0] state;
    reg [7:0] header[0:33];
    reg [31:0] length,bytes_left,offset;
    reg [X_BITS-1:0] x,last_x;
    reg [ROW_BITS-1:0] row,last_y;
    reg [1:0] phase,pad_left;
    reg last_pixel_cached,last_row_cached;
    wire [1:0] padding=width[1:0];
    reg [7:0] blue,green;
    // HEADER复用低6位索引；PIXELS首字节完整覆写blue后才组装RGB。
    wire [5:0] header_index=blue[5:0];
    reg [31:0] row_stride;
    reg [32:0] minimum_offset;
    reg [47:0] payload_size;
    reg [48:0] pixel_end;
    reg [31:0] normalized_width,normalized_height;
    reg normalized_bottom_up;
    wire [31:0] hsize={header[5],header[4],header[3],header[2]};
    wire [31:0] hoff={header[13],header[12],header[11],header[10]};
    wire [31:0] dib={header[17],header[16],header[15],header[14]};
    wire [31:0] w={header[21],header[20],header[19],header[18]};
    wire [31:0] signed_h={header[25],header[24],header[23],header[22]};
    wire [31:0] abs_h=signed_h[31]?(~signed_h+1'b1):signed_h;
    wire [15:0] planes={header[27],header[26]},bpp={header[29],header[28]};
    wire [31:0] compression={header[33],header[32],header[31],header[30]};
    wire last_row=last_row_cached;
    wire last_pixel=last_pixel_cached;
    wire [ROW_BITS-1:0] reversed_row=last_y-row;
    wire [STRIDE_BITS-1:0] row_bytes={{(STRIDE_BITS-WIDTH_BITS){1'b0}},width[WIDTH_BITS-1:0]};
    wire [STRIDE_BITS-1:0] aligned_stride=(row_bytes+(row_bytes<<1)+{{(STRIDE_BITS-2){1'b0}},2'd3})
                                            & {{(STRIDE_BITS-2){1'b1}},2'b00};
    wire [PRODUCT_BITS-1:0] bounded_payload=row_stride[STRIDE_BITS-1:0]*height[HEIGHT_BITS-1:0];
    wire [31:0] offset_step=(state==RANGE_CHECK)?32'd54:32'd1;
    wire [31:0] next_offset=offset-offset_step;
    assign busy=!(state==IDLE || state==FINISHED || state==FAILED);
    assign in_ready=(state==HEADER || state==SKIP || state==PIXELS || state==PADDING || state==TAIL)
                    && (!pixel_valid || pixel_ready);

    task fail;
        input [3:0] code;
        begin state<=FAILED; error<=1; error_code<=code; end
    endtask
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE; length<=0; bytes_left<=0; offset<=0;
            x<=0; row<=0; phase<=0; pad_left<=0; blue<=0; green<=0;
            last_pixel_cached<=0;last_row_cached<=0;
            last_x<=0;last_y<=0;
            pixel_valid<=0; pixel_rgb<=0; pixel_x<=0; pixel_y<=0;
            width<=0; height<=0; bottom_up<=0; done<=0; error<=0; error_code<=0;
            header_valid<=0;
            row_stride<=0; minimum_offset<=0; payload_size<=0; pixel_end<=0;
            normalized_width<=0;normalized_height<=0;normalized_bottom_up<=0;
        end else if(abort) begin
            state<=IDLE; pixel_valid<=0; done<=0; error<=0; error_code<=0; header_valid<=0;
        end else if(start && !busy) begin
            state<=HEADER; length<=file_size; bytes_left<=file_size; offset<=0;blue[5:0]<=0;
            x<=0; row<=0; phase<=0; pixel_valid<=0; done<=0; error<=0; error_code<=0;
            last_pixel_cached<=0;last_row_cached<=0;
            width<=0; height<=0; header_valid<=0;
            if(file_size<54) fail(1);
        end else begin
            if(pixel_valid && pixel_ready) pixel_valid<=0;
            // 有符号高度归一化与尺寸比较分拍，避免取反加一串接32位比较器。
            if(state==NORMALIZE)begin
                normalized_width<=w;normalized_height<=abs_h;normalized_bottom_up<=!signed_h[31];
                state<=CHECK;
            end
            if(state==CHECK) begin
                if(header[0]!=8'h42 || header[1]!=8'h4d || dib<40 || planes!=1 || bpp!=24 || compression!=0)
                    fail(2);
                else if(normalized_width==0 || normalized_width>MAX_WIDTH || normalized_width>65535 ||
                        normalized_height==0 || normalized_height>MAX_HEIGHT || normalized_height>65535)
                    fail(3);
                else begin
                    width<={{(16-WIDTH_BITS){1'b0}},normalized_width[WIDTH_BITS-1:0]};
                    height<={{(16-HEIGHT_BITS){1'b0}},normalized_height[HEIGHT_BITS-1:0]};
                    bottom_up<=normalized_bottom_up; offset<=hoff;
                    state<=LAYOUT;
                end
            end
            // 头字段的乘法、偏移加法与范围比较分拍完成，避免长组合校验路径。
            if(state==LAYOUT) begin
                // CHECK已验证完整尺寸，提前保存末坐标以缩短逐字节EOF判定。
                last_x<=width-1'b1;last_y<=height-1'b1;
                row_stride<={{(32-STRIDE_BITS){1'b0}},aligned_stride};
                minimum_offset<={1'b0,dib}+33'd14;
                state<=PRODUCT;
            end
            if(state==PRODUCT) begin payload_size<={{(48-PRODUCT_BITS){1'b0}},bounded_payload}; state<=END_OFFSET; end
            if(state==END_OFFSET) begin pixel_end<={1'b0,payload_size}+{17'd0,offset}; state<=RANGE_CHECK; end
            if(state==RANGE_CHECK) begin
                if({1'b0,offset}<minimum_offset || pixel_end>{17'd0,length} ||
                   {17'd0,hsize}<pixel_end || hsize>length) fail(4);
                else begin
                    header_valid<=1;state<=(offset==54)?PIXELS:SKIP;
                    // 绝对偏移校验已完成，复用为SKIP剩余字节，合法offset至少54。
                    offset<=next_offset;
                end
            end
            if(state==FLUSH && (!pixel_valid || pixel_ready)) begin state<=FINISHED; done<=1; end
            if(in_valid && in_ready) begin
                bytes_left<=bytes_left-1'b1;
                case(state)
                    HEADER: begin
                        if(header_index<34)header[header_index]<=in_data;
                        blue[5:0]<=header_index+1'b1;
                        if(header_index==53)state<=NORMALIZE;
                    end
                    SKIP: begin offset<=next_offset;if(offset==1)state<=PIXELS;end
                    PIXELS: begin
                        case(phase)
                            0: begin
                                // 蓝字节准备端点，坐标在红字节/填充消费前保持。
                                blue<=in_data;phase<=1;
                                last_pixel_cached<=x==last_x;last_row_cached<=row==last_y;
                            end
                            1: begin green<=in_data; phase<=2; end
                            2: begin
                                pixel_rgb<={in_data,green,blue}; pixel_x<=x;
                                pixel_y<=bottom_up ? {{(16-ROW_BITS){1'b0}},reversed_row} : {{(16-ROW_BITS){1'b0}},row};
                                pixel_valid<=1; phase<=0;
                                if(last_pixel) begin
                                    x<=0;
                                    if(padding!=0) begin pad_left<=padding; state<=PADDING; end
                                    else if(last_row) state<=TAIL;
                                    else row<=row+1'b1;
                                end else x<=x+1'b1;
                            end
                        endcase
                    end
                    PADDING: begin
                        pad_left<=pad_left-1'b1;
                        if(pad_left==1) begin
                            if(last_row) state<=TAIL;
                            else begin row<=row+1'b1; state<=PIXELS; end
                        end
                    end
                endcase
                if(in_last) begin
                    if(bytes_left!=1) fail(5);
                    else if(state==TAIL || (state==PIXELS && phase==2 && last_pixel && last_row && padding==0) ||
                            (state==PADDING && last_row && pad_left==1)) state<=FLUSH;
                    else fail(5);
                end else if(bytes_left<=1) fail(5);
            end
        end
    end
endmodule
