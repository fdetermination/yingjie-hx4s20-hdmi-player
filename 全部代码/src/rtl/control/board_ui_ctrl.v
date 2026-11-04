`timescale 1ns/1ps
// 两键释放时分派短/长按；双键会话抑制单键动作直到全部释放。
module board_ui_ctrl #(
    parameter integer CLK_HZ=125000000,
    parameter integer DEBOUNCE_CYCLES=CLK_HZ/50,
    parameter integer HOLD_CYCLES=CLK_HZ/10*8,
    parameter integer RESTART_CYCLES=CLK_HZ*2
)(
    input wire clk,rst,key_next_n,key_auto_n,
    output reg next_pulse,auto_pulse,restart_pulse,
    output reg menu_open,
    output reg [2:0] menu_item,
    output reg [1:0] interval_sel,
    output reg signed [8:0] brightness,
    output reg [7:0] contrast,
    output reg subtitle_enable,spectrum_enable
);
    localparam HOLD_BITS=HOLD_CYCLES<2?1:$clog2(HOLD_CYCLES+1);
    localparam RESTART_BITS=RESTART_CYCLES<2?1:$clog2(RESTART_CYCLES+1);
    wire next_down,auto_down;
    reg next_previous,auto_previous,chord,chord_sent;
    reg [HOLD_BITS-1:0] next_count,auto_count;
    reg [RESTART_BITS-1:0] chord_count;
    button_debounce #(.CYCLES(DEBOUNCE_CYCLES)) next_key(.clk(clk),.rst(rst),.key_n(key_next_n),.pressed(next_down));
    button_debounce #(.CYCLES(DEBOUNCE_CYCLES)) auto_key(.clk(clk),.rst(rst),.key_n(key_auto_n),.pressed(auto_down));
    task cycle_interval;
        begin interval_sel<=interval_sel==2?0:interval_sel+1'b1;end
    endtask
    task reset_selected;
        begin case(menu_item)
            0:interval_sel<=0;1:brightness<=0;2:contrast<=128;
            3:subtitle_enable<=1;4:spectrum_enable<=1;
        endcase end
    endtask
    task change_selected;
        begin case(menu_item)
            0:cycle_interval();
            1:brightness <= brightness >= 9'sd112 ? -9'sd128 : brightness + 9'sd16;
            2:contrast<=contrast>=192?64:contrast+8'd16;
            3:subtitle_enable<=!subtitle_enable;
            4:spectrum_enable<=!spectrum_enable;
        endcase end
    endtask
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            next_pulse<=0;auto_pulse<=0;restart_pulse<=0;menu_open<=0;menu_item<=0;
            interval_sel<=0;brightness<=0;contrast<=128;subtitle_enable<=1;spectrum_enable<=1;
            next_previous<=0;auto_previous<=0;chord<=0;chord_sent<=0;
            next_count<=0;auto_count<=0;chord_count<=0;
        end else begin
            next_pulse<=0;auto_pulse<=0;restart_pulse<=0;
            next_previous<=next_down;auto_previous<=auto_down;
            if(next_down)begin if(next_count<HOLD_CYCLES)next_count<=next_count+1'b1;end
            else next_count<=0;
            if(auto_down)begin if(auto_count<HOLD_CYCLES)auto_count<=auto_count+1'b1;end
            else auto_count<=0;
            if(next_down && auto_down)begin
                chord<=1;
                if(!chord_sent)begin
                    if(chord_count==RESTART_CYCLES-1)begin
                        chord_sent<=1;restart_pulse<=1;menu_open<=0;
                    end else chord_count<=chord_count+1'b1;
                end
            end else begin
                chord_count<=0;
                if(chord)begin
                    if(!next_down && !auto_down)begin chord<=0;chord_sent<=0;end
                end else begin
                    if(next_previous && !next_down)begin
                        if(menu_open)begin
                            if(next_count>=HOLD_CYCLES)reset_selected();
                            else menu_item<=menu_item==4?0:menu_item+1'b1;
                        end else if(next_count>=HOLD_CYCLES)cycle_interval();
                        else next_pulse<=1;
                    end
                    if(auto_previous && !auto_down)begin
                        if(auto_count>=HOLD_CYCLES)begin menu_open<=!menu_open;menu_item<=0;end
                        else if(menu_open)change_selected();
                        else auto_pulse<=1;
                    end
                end
            end
        end
    end
endmodule
