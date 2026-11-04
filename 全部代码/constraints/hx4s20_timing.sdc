# 板级初次布局布线约束：保留pixel/serial和mem/PHY的真实相位关系。
# TF外部IO由board_tf_constraints.tcl按各阶段实际SCLK输出时钟引脚加载；板上电气与功能仍需验收。
create_clock -name clk_50 -period 20 [get_ports clk_50]
# 先只派生视频PLL；SYS的细相位会被derive取整到度，按真实参数显式定义。
derive_clocks -instance [get_cells {video_pll/pll}]
rename_clock -name pixel_clk [get_clocks {video_pll/pll.clkc[1]}]
rename_clock -name serial_clk [get_clocks {video_pll/pll.clkc[2]}]
create_generated_clock -name ctrl_clk -source [get_ports clk_50] -master_clock clk_50 -multiply_by 2 [get_pins {sys_pll/pll.clkc[0]}]
create_generated_clock -name mem_clk -source [get_ports clk_50] -master_clock clk_50 -multiply_by 2.5 [get_pins {sys_pll/pll.clkc[1]}]
create_generated_clock -name sdram_phy_clk -source [get_ports clk_50] -master_clock clk_50 -multiply_by 2.5 -phase 230.625 [get_pins {sys_pll/pll.clkc[2]}]
create_generated_clock -name sdram_capture_clk -source [get_ports clk_50] -master_clock clk_50 -multiply_by 2.5 -phase 28.125 [get_pins {sys_pll/pll.clkc[3]}]
foreach name {ctrl_clk mem_clk sdram_phy_clk sdram_capture_clk pixel_clk serial_clk} {
    if {![llength [get_clocks $name]]} {error "Required board clock $name missing"}
}
# DQ每拍更新；采样前一PHY周期的字。仅setup/end2，保留下一字的严格保持检查。
set_multicycle_path -setup -end -from [get_pins -hier -regexp {^core/memory/memory\.dq\[[0-9]+\]$}] -to [get_clocks sdram_capture_clk] 2
set wr_meta [get_regs -hier -regexp {.*wr_gray_meta\[[0-9]+\]$}]
set rd_meta [get_regs -hier -regexp {.*rd_gray_meta\[[0-9]+\]$}]
if {![llength $wr_meta] || ![llength $rd_meta]} {error "Pixel/audio Gray endpoints missing"}
set_max_delay 4 -datapath_only -from [get_clocks mem_clk] -to [get_regs -hier -regexp {^core/scanout/.*wr_gray_meta\[[0-9]+\]$}]
set_min_delay 0 -from [get_clocks mem_clk] -to [get_regs -hier -regexp {^core/scanout/.*wr_gray_meta\[[0-9]+\]$}]
set_max_skew 4 -from_clock [get_clocks mem_clk] -to [get_regs -hier -regexp {^core/scanout/.*wr_gray_meta\[[0-9]+\]$}]
set_max_delay 4 -datapath_only -from [get_clocks ctrl_clk] -to [get_regs -hier -regexp {^core/(application/audio/.*|writes/commands/)wr_gray_meta\[[0-9]+\]$}]
set_min_delay 0 -from [get_clocks ctrl_clk] -to [get_regs -hier -regexp {^core/(application/audio/.*|writes/commands/)wr_gray_meta\[[0-9]+\]$}]
set_max_skew 4 -from_clock [get_clocks ctrl_clk] -to [get_regs -hier -regexp {^core/(application/audio/.*|writes/commands/)wr_gray_meta\[[0-9]+\]$}]
set_max_delay 4 -datapath_only -from [get_clocks pixel_clk] -to [get_regs -hier -regexp {^core/(scanout/.*|application/audio/.*)rd_gray_meta\[[0-9]+\]$}]
set_min_delay 0 -from [get_clocks pixel_clk] -to [get_regs -hier -regexp {^core/(scanout/.*|application/audio/.*)rd_gray_meta\[[0-9]+\]$}]
set_max_skew 4 -from_clock [get_clocks pixel_clk] -to [get_regs -hier -regexp {^core/(scanout/.*|application/audio/.*)rd_gray_meta\[[0-9]+\]$}]
set_max_delay 4 -datapath_only -from [get_clocks mem_clk] -to [get_regs -hier -regexp {^core/writes/commands/rd_gray_meta\[[0-9]+\]$}]
set_min_delay 0 -from [get_clocks mem_clk] -to [get_regs -hier -regexp {^core/writes/commands/rd_gray_meta\[[0-9]+\]$}]
set_max_skew 4 -from_clock [get_clocks mem_clk] -to [get_regs -hier -regexp {^core/writes/commands/rd_gray_meta\[[0-9]+\]$}]
# SWUG105 4.4.9：get_regs按逻辑Q网络映射寄存器，打包成其他cell名后仍可定位。
# 请求/应答只限定第一级捕获，第二级保持正常本域时序。
set req_meta [get_regs {core/presentation/config_cdc/request_meta}]
set ack_meta [get_regs {core/presentation/config_cdc/ack_meta}]
set config_dst [get_regs -hier -regexp {^core/presentation/config_cdc/received\[[0-9]+\]$}]
if {![llength $config_dst] || ![llength $req_meta] || ![llength $ack_meta]} {error "Configuration CDC endpoints missing"}
# TD此版本将变量中的get_regs结果当作普通net而静默命中0路径，必须保留内联查询。
set_max_delay 4 -datapath_only -from [get_clocks ctrl_clk] -to [get_regs {core/presentation/config_cdc/request_meta}]
set_min_delay 0 -from [get_clocks ctrl_clk] -to [get_regs {core/presentation/config_cdc/request_meta}]
set_max_delay 4 -datapath_only -from [get_clocks pixel_clk] -to [get_regs {core/presentation/config_cdc/ack_meta}]
set_min_delay 0 -from [get_clocks pixel_clk] -to [get_regs {core/presentation/config_cdc/ack_meta}]
# datapath_only自动忽略这些异步capture的hold；下游像素路径继续正常计时。
set_max_delay 12 -datapath_only -from [get_clocks ctrl_clk] -to [get_regs -hier -regexp {^core/presentation/config_cdc/received\[[0-9]+\]$}]
set_min_delay 0 -from [get_clocks ctrl_clk] -to [get_regs -hier -regexp {^core/presentation/config_cdc/received\[[0-9]+\]$}]
# 单bit同步链只放宽到第一级，第二级继续按本域时钟计时。
if {[llength [get_regs {core/scanout/run_meta core/scanout/dual_meta core/scanout/stop_meta}]]!=3} {error "Pixel control CDC first stages missing"}
if {[llength [get_regs {core/scanout/fault_meta core/scanout/stopped_meta core/scanout/transition_meta}]]!=3} {error "Memory status CDC first stages missing"}
set_max_delay 4 -datapath_only -from [get_clocks mem_clk] -to [get_regs {core/scanout/run_meta core/scanout/dual_meta core/scanout/stop_meta}]
set_min_delay 0 -from [get_clocks mem_clk] -to [get_regs {core/scanout/run_meta core/scanout/dual_meta core/scanout/stop_meta}]
set_max_delay 4 -datapath_only -from [get_clocks pixel_clk] -to [get_regs {core/scanout/fault_meta core/scanout/stopped_meta core/scanout/transition_meta}]
set_min_delay 0 -from [get_clocks pixel_clk] -to [get_regs {core/scanout/fault_meta core/scanout/stopped_meta core/scanout/transition_meta}]
set_max_delay 4 -datapath_only -from [get_clocks pixel_clk] -to [get_regs {core/line_fault_meta core/sessions/boundary_meta}]
set_min_delay 0 -from [get_clocks pixel_clk] -to [get_regs {core/line_fault_meta core/sessions/boundary_meta}]
# 双曲目准备/EOF、场景arm/cancel与返回状态只限制第一级。
set_max_delay 4 -datapath_only -from [get_clocks ctrl_clk] -to [get_regs -hier -regexp {.*audio/.*(prepare_meta|eof_meta|request_meta|cancel_meta)$}]
set_min_delay 0 -from [get_clocks ctrl_clk] -to [get_regs -hier -regexp {.*audio/.*(prepare_meta|eof_meta|request_meta|cancel_meta)$}]
set_max_delay 4 -datapath_only -from [get_clocks pixel_clk] -to [get_regs -hier -regexp {.*audio/.*(clear_meta|released_meta|generation_meta|prepared_meta|ack_meta|started_meta|error_meta|cancelled_meta|active_meta)$}]
set_min_delay 0 -from [get_clocks pixel_clk] -to [get_regs -hier -regexp {.*audio/.*(clear_meta|released_meta|generation_meta|prepared_meta|ack_meta|started_meta|error_meta|cancelled_meta|active_meta)$}]
set_max_delay 12 -datapath_only -from [get_clocks ctrl_clk] -to [get_regs -hier -regexp {.*audio/.*(token_received\[[0-9]+\]|received_has_audio|received\[[0-9]+\])$}]
set_min_delay 0 -from [get_clocks ctrl_clk] -to [get_regs -hier -regexp {.*audio/.*(token_received\[[0-9]+\]|received_has_audio|received\[[0-9]+\])$}]
set_max_delay 12 -datapath_only -from [get_clocks mem_clk] -to [get_regs -hier -regexp {^core/scanout/pixel_scene_token\[[0-9]+\]$}]
set_min_delay 0 -from [get_clocks mem_clk] -to [get_regs -hier -regexp {^core/scanout/pixel_scene_token\[[0-9]+\]$}]
# 100/125同源时钟仍正常计时，只限定真正握手/Gray结构的第一级。
set_max_delay 4 -datapath_only -from [get_clocks ctrl_clk] -to [get_regs {core/writes/cancel_meta core/session_bridge/request_meta core/session_bridge/stop_meta}]
set_min_delay 0 -from [get_clocks ctrl_clk] -to [get_regs {core/writes/cancel_meta core/session_bridge/request_meta core/session_bridge/stop_meta}]
set_max_delay 4 -datapath_only -from [get_clocks mem_clk] -to [get_regs {core/writes/begin_meta core/writes/flush_meta core/writes/cancelled_meta core/writes/error_meta core/session_bridge/ack_meta core/session_bridge/stopped_meta core/session_bridge/error_meta core/session_bridge/underflow_meta core/session_bridge/transition_meta}]
set_min_delay 0 -from [get_clocks mem_clk] -to [get_regs {core/writes/begin_meta core/writes/flush_meta core/writes/cancelled_meta core/writes/error_meta core/session_bridge/ack_meta core/session_bridge/stopped_meta core/session_bridge/error_meta core/session_bridge/underflow_meta core/session_bridge/transition_meta}]
set_max_delay 12 -datapath_only -from [get_clocks ctrl_clk] -to [get_regs -hier -regexp {^core/session_bridge/received\[[0-9]+\]$}]
set_min_delay 0 -from [get_clocks ctrl_clk] -to [get_regs -hier -regexp {^core/session_bridge/received\[[0-9]+\]$}]
# 按键一级可能打包进输入PAD；异步引脚到第一个采样点没有同步到达时间要求。
# 时序遍历在寄存器终止，因此不会切断meta->sync的同步路径。
set_false_path -from [get_ports {key_next key_auto}]
# 复位同步器SR由board_reset_constraints.tcl在gate/route阶段按逻辑Q映射。
# 生成逐端点SDC并检查实际命中；同步释放后的功能寄存器继续检查。
