# ---------------------------------------------------------------------------
# Barrido de frecuencias del reloj del sistema (I-57, docs/timing/README.md).
#
#   En batch, desde la raíz del repo:
#       vivado -mode batch -source scripts/barrido.tcl -tclargs 65 68 70 72 74 76
#   o en la Tcl Console, sin proyecto abierto:
#       set BARRIDO_MHZ {65 68 70 72}
#       source <ruta-al-repo>/scripts/barrido.tcl
#
# Para cada frecuencia pedida (en MHz) cambia la salida de clk_wiz_sys
# (CLKOUT1_REQUESTED_OUT_FREQ de ip/clk_wiz.tcl), regenera el IP, pone el
# CLK_FREQ_HZ del top en la frecuencia que da el MMCM y vuelve a sintetizar e
# implementar desde cero, con la estrategia por defecto. Después escribe en
# build/timing/barrido/<MHz>/ el report_timing_summary, report_utilization y
# report_power, y agrega una línea a build/timing/barrido/barrido.csv con:
#
#   mhz_pedida, mhz_real, D, M, O    lo que eligió el wizard (MMCM: VCO = 100 × M / D,
#                                    salida = VCO / O) y el período real
#   wns, tns, whs, ths, fallan       setup y hold post-implementación (STATS del run)
#   unc                              clock uncertainty del peor camino (incluye el jitter)
#   datos, niveles                   retardo de datos y niveles de lógica del peor camino
#   lut, ff, bram, mmcm              utilización
#   p_total, p_din, p_est            consumo estimado (W), report_power por defecto
#   dvsr, baud, err                  divisor de la UART (DVSR = round(f / (16 × BAUD))),
#                                    baudrate real y error, como los calcula rtl/peripherals/uart/uart.v
#
# Regenera desde cero build/vivado_riscv_basys3 con create_project.tcl (pisa el
# proyecto que haya ahí: conviene correrlo en una copia aparte del repo, como la
# de la regresión) y cambia solo el proyecto, no los archivos versionados:
# ip/clk_wiz.tcl y el top quedan como están. La
# frecuencia elegida se fija después a mano en los tres lugares de la decisión
# 042 (ip/clk_wiz.tcl, CLK_FREQ_HZ del top y F_SYS de tb/unit/top_tb.v).
# ---------------------------------------------------------------------------
set bar_root [file normalize [file join [file dirname [info script]] ..]]

if {[info exists argv] && [llength $argv] >= 1} { set BARRIDO_MHZ $argv }
if {![info exists BARRIDO_MHZ]} { set BARRIDO_MHZ {65 68 70 72 74 76 78 80} }

set bar_baud 115200
set bar_dir  [file join $bar_root build timing barrido]
file mkdir $bar_dir

# Proyecto desde cero
catch {close_project}
set DESIGN riscv_basys3
set bar_cwd [pwd]
cd $bar_root
source [file join $bar_root scripts create_project.tcl]
cd $bar_cwd
if {[get_property top [get_filesets sources_1]] ne "top"} {
    error "El top de sources_1 no es el módulo top de fpga/riscv_basys3"
}
set bar_ip [get_ips clk_wiz_sys]

# Primer número de una tabla de report_* después de la etiqueta, o "?"
proc bar_num {texto patron} {
    if {[regexp -line "$patron\\s*\\|\\s*(\[0-9.<>-\]+)" $texto -> v]} { return $v }
    return "?"
}

set csv [file join $bar_dir barrido.csv]
set f [open $csv w]
puts $f "mhz_pedida,mhz_real,D,M,O,wns,tns,whs,ths,fallan,unc,datos,niveles,lut,ff,bram,mmcm,p_total,p_din,p_est,dvsr,baud,err"
close $f

foreach mhz $BARRIDO_MHZ {
    puts "\n=== Barrido: $mhz MHz ==="
    catch {close_design}

    # Clock Wizard con la nueva salida; el wizard elige D, M y O
    set_property CONFIG.CLKOUT1_REQUESTED_OUT_FREQ [format %.3f $mhz] $bar_ip
    generate_target all $bar_ip
    catch {reset_run clk_wiz_sys_synth_1}
    set D [get_property CONFIG.MMCM_DIVCLK_DIVIDE   $bar_ip]
    set M [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $bar_ip]
    set O [get_property CONFIG.MMCM_CLKOUT0_DIVIDE_F $bar_ip]
    set hz [expr {round(100.0e6 * $M / ($D * $O))}]

    # CLK_FREQ_HZ del top = salida real del MMCM (UART, INFO, timeout)
    set_property generic "CLK_FREQ_HZ=$hz" [get_filesets sources_1]

    reset_run synth_1
    launch_runs impl_1 -jobs 4
    wait_on_run impl_1
    set run [get_runs impl_1]
    if {[get_property PROGRESS $run] ne "100%"} {
        puts "ERROR: impl_1 no terminó a $mhz MHz; sigo con la próxima"
        set f [open $csv a]
        puts $f "$mhz,[expr {$hz / 1.0e6}],$D,$M,$O,impl_fallo"
        close $f
        continue
    }
    open_run impl_1

    set out [file join $bar_dir $mhz]
    file mkdir $out
    report_timing_summary -max_paths 1 -file [file join $out timing_summary.rpt]
    set util [report_utilization -return_string]
    set pwr  [report_power -return_string]
    set fu [open [file join $out utilization.rpt] w]; puts $fu $util; close $fu
    set fp [open [file join $out power.rpt] w];       puts $fp $pwr;  close $fp

    set per [get_property PERIOD [get_clocks clk_out1_clk_wiz_sys]]
    set peor [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
    set fallan [llength [get_timing_paths -delay_type max -max_paths 100000 -nworst 1 -slack_lesser_than 0]]

    set dvsr [expr {($hz + 8 * $bar_baud) / (16 * $bar_baud)}]
    set baud [expr {double($hz) / (16 * $dvsr)}]
    set err  [expr {100.0 * ($baud / $bar_baud - 1)}]

    set fila [list $mhz [format %.4f [expr {1000.0 / $per}]] $D $M $O \
        [get_property STATS.WNS $run] [get_property STATS.TNS $run] \
        [get_property STATS.WHS $run] [get_property STATS.THS $run] $fallan \
        [get_property UNCERTAINTY $peor] [get_property DATAPATH_DELAY $peor] \
        [get_property LOGIC_LEVELS $peor] \
        [bar_num $util {Slice LUTs\*?}] [bar_num $util {Slice Registers}] \
        [bar_num $util {Block RAM Tile}] [bar_num $util {MMCME2_ADV}] \
        [bar_num $pwr {Total On-Chip Power \(W\)}] [bar_num $pwr {Dynamic \(W\)}] \
        [bar_num $pwr {Device Static \(W\)}] \
        $dvsr [format %.0f $baud] [format %+.2f $err]]
    set f [open $csv a]
    puts $f [join $fila ,]
    close $f
    puts "Barrido $mhz MHz: [join $fila ,]"
}

puts "\n=== Barrido terminado: $csv ==="
set f [open $csv r]; puts [read $f]; close $f
