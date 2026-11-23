# ---------------------------------------------------------------------------
# Análisis de timing del diseño riscv_basys3 (I-56, docs/timing/README.md).
#
#   En la Tcl Console de Vivado, con el proyecto abierto o sin ninguno:
#       set TIMING_TAG base          ;# opcional, nombre de la medición
#       set TIMING_IMPL 0            ;# opcional: 0 = usar la implementación que ya hay
#       source <ruta-al-repo>/scripts/timing.tcl
#   o en batch:
#       vivado -mode batch -source scripts/timing.tcl -tclargs [etiqueta] [0|1]
#
# Usa el proyecto abierto tal como está. Si no hay ninguno, con TIMING_IMPL = 1
# (por defecto) regenera build/vivado_riscv_basys3 con create_project.tcl y
# vuelve a sintetizar e implementar desde cero, para que la medición corresponda
# al working tree: los IP se configuran solo al crear el proyecto, así que
# reabrir uno viejo mediría el reloj de ip/clk_wiz.tcl de cuando se creó (I-57).
# Con TIMING_IMPL = 0 abre el proyecto que haya. Después abre impl_1 y escribe en
# build/timing/<etiqueta>/:
#
#   timing_summary.rpt    report_timing_summary con el peor camino de setup y de
#                         hold detallados; es el que se versiona en docs/timing/
#   setup_top30.rpt       los 30 peores caminos de setup, con el reloj expandido
#                         (retardo de reloj en origen y destino, skew, uncertainty),
#                         como los que se miraron en la I-49
#   hold_top10.rpt        los 10 peores de hold, con el reloj expandido
#   por_etapa.rpt         el peor camino de setup que termina en cada grupo de
#                         registros (PC, IF/ID, ID/EX, EX/MEM, MEM/WB, banco, BRAM,
#                         Debug Unit, UART)
#   compromisos.rpt       los caminos que piden revisar las decisiones 018/037
#                         (halted -> enable -> CE) y 014 (clock-to-out de las BRAM)
#   clocks.rpt, clock_networks.rpt, clock_utilization.rpt   la red de reloj (skew)
#   resumen.txt           una línea por grupo: slack, skew, niveles, origen y destino
#
# No cambia el proyecto ni el RTL. El reloj y la frecuencia son los del
# ip/clk_wiz.tcl del working tree (decisión 042).
# ---------------------------------------------------------------------------
set tim_root [file normalize [file join [file dirname [info script]] ..]]

# Parámetros: variables de la consola o argumentos de batch
if {[info exists argv] && [llength $argv] >= 1} { set TIMING_TAG  [lindex $argv 0] }
if {[info exists argv] && [llength $argv] >= 2} { set TIMING_IMPL [lindex $argv 1] }
if {![info exists TIMING_TAG]}  { set TIMING_TAG base }
if {![info exists TIMING_IMPL]} { set TIMING_IMPL 1 }

set tim_dir [file join $tim_root build timing $TIMING_TAG]
file mkdir $tim_dir

# Proyecto: el abierto; si no, uno nuevo (o el de build/ con TIMING_IMPL = 0)
if {[catch {current_project}]} {
    set xpr [file join $tim_root build vivado_riscv_basys3 riscv_basys3.xpr]
    if {!$TIMING_IMPL && [file exists $xpr]} {
        open_project $xpr
    } else {
        set DESIGN riscv_basys3
        source [file join $tim_root scripts create_project.tcl]
    }
}
if {[get_property top [get_filesets sources_1]] ne "top"} {
    error "El top de sources_1 no es el módulo top de fpga/riscv_basys3"
}

# Implementación
if {$TIMING_IMPL} {
    reset_run synth_1
    launch_runs impl_1 -jobs 4
    wait_on_run impl_1
}
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "impl_1 no terminó: corré con TIMING_IMPL = 1 o revisá los mensajes del run"
}
catch {close_design}
open_run impl_1

# ---------------------------------------------------------------------------
# Reportes completos
# ---------------------------------------------------------------------------
proc tim_file {nombre} { return [file join $::tim_dir $nombre] }

report_timing_summary -max_paths 1 -file [tim_file timing_summary.rpt]
report_timing -delay_type max -max_paths 30 -nworst 1 -path_type full_clock_expanded \
    -input_pins -file [tim_file setup_top30.rpt]
report_timing -delay_type min -max_paths 10 -nworst 1 -path_type full_clock_expanded \
    -input_pins -file [tim_file hold_top10.rpt]
report_clocks             -file [tim_file clocks.rpt]
report_clock_networks     -file [tim_file clock_networks.rpt]
report_clock_utilization  -file [tim_file clock_utilization.rpt]

# ---------------------------------------------------------------------------
# Peor camino por grupo de registros
# ---------------------------------------------------------------------------
# Celdas secuenciales (FF, LUTRAM, BRAM) cuyo nombre jerárquico coincide con el patrón
proc tim_cells {patron} {
    return [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL && NAME =~ $patron"]
}

# Una línea del resumen con el peor camino de una lista de get_timing_paths
proc tim_linea {grupo caminos} {
    if {[llength $caminos] == 0} {
        return [format "%-26s (sin caminos: revisar el patrón)" $grupo]
    }
    set p [lindex $caminos 0]
    set prop {}
    foreach k {SLACK SKEW UNCERTAINTY DATAPATH_DELAY LOGIC_LEVELS STARTPOINT_PIN ENDPOINT_PIN} {
        if {[catch {set v [get_property $k $p]}]} { set v "?" }
        dict set prop $k $v
    }
    return [format "%-26s slack %8s  skew %7s  unc %6s  datos %7s  niveles %3s  %s -> %s" \
        $grupo [dict get $prop SLACK] [dict get $prop SKEW] [dict get $prop UNCERTAINTY] \
        [dict get $prop DATAPATH_DELAY] [dict get $prop LOGIC_LEVELS] \
        [dict get $prop STARTPOINT_PIN] [dict get $prop ENDPOINT_PIN]]
}

# Grupos por destino: etapa donde se captura el dato
set grupos {
    "IF: pc_reg"            "*u_pc_logic/pc_reg*"
    "IF: imem_bram"         "*u_imem/u_imem_bram/*"
    "IF/ID"                 "*u_if_id_reg/*"
    "ID/EX"                 "*u_id_ex_reg/*"
    "EX/MEM"                "*u_ex_mem_reg/*"
    "MEM: dmem_bram"        "*u_dmem/u_dmem_bram/*"
    "MEM/WB"                "*u_mem_wb_reg/*"
    "WB: banco"             "*u_regfile/*"
    "WB: halted/imem_fault" "*u_wb_stage/*"
    "Debug Unit"            "*u_debug_*"
    "UART"                  "*u_uart/*"
    "reset_sync"            "*u_reset_sync/*"
}

set resumen [list]
lappend resumen "Timing de riscv_basys3, medición '$TIMING_TAG' ([clock format [clock seconds] -format {%Y-%m-%d %H:%M}])"
foreach clk [get_clocks] {
    lappend resumen [format "Reloj %-24s período %s ns" $clk [get_property PERIOD $clk]]
}
lappend resumen ""

lappend resumen "== Peor camino de setup y de hold de todo el diseño =="
lappend resumen [tim_linea "setup (WNS)" [get_timing_paths -delay_type max -max_paths 1]]
lappend resumen [tim_linea "hold (WHS)"  [get_timing_paths -delay_type min -max_paths 1]]
lappend resumen ""

set f [open [tim_file por_etapa.rpt] w]
puts $f "Peor camino de setup que termina en cada grupo (scripts/timing.tcl)"
close $f
lappend resumen "== Setup: peor camino que termina en cada grupo =="
foreach {grupo patron} $grupos {
    set celdas [tim_cells $patron]
    if {[llength $celdas] == 0} {
        lappend resumen [format "%-26s (ninguna celda con %s)" $grupo $patron]
        continue
    }
    set caminos [get_timing_paths -delay_type max -max_paths 1 -to $celdas]
    lappend resumen [tim_linea $grupo $caminos]
    if {[llength $caminos] > 0} {
        report_timing -of_objects $caminos -path_type full_clock_expanded -input_pins -append -file [tim_file por_etapa.rpt]
    }
}
lappend resumen ""

lappend resumen "== Hold: peor camino que termina en cada grupo =="
foreach {grupo patron} $grupos {
    set celdas [tim_cells $patron]
    if {[llength $celdas] == 0} { continue }
    lappend resumen [tim_linea $grupo [get_timing_paths -delay_type min -max_paths 1 -to $celdas]]
}
lappend resumen ""

# ---------------------------------------------------------------------------
# Compromisos de otras decisiones
# ---------------------------------------------------------------------------
set f [open [tim_file compromisos.rpt] w]
puts $f "Caminos que piden revisar las decisiones 018/037 y 014 (scripts/timing.tcl)"
close $f
lappend resumen "== Compromisos (018/037: halted -> enable -> CE; 014: clock-to-out de las BRAM) =="
set desde {
    "desde halted"     "*u_wb_stage/halted_reg*"
    "desde debug_exec" "*u_debug_exec/*"
    "desde dmem_bram"  "*u_dmem/u_dmem_bram/*"
    "desde imem_bram"  "*u_imem/u_imem_bram/*"
}
foreach {grupo patron} $desde {
    set celdas [tim_cells $patron]
    if {[llength $celdas] == 0} {
        lappend resumen [format "%-26s (ninguna celda con %s)" $grupo $patron]
        continue
    }
    set caminos [get_timing_paths -delay_type max -max_paths 1 -from $celdas]
    lappend resumen [tim_linea $grupo $caminos]
    if {[llength $caminos] > 0} {
        report_timing -of_objects $caminos -path_type full_clock_expanded -input_pins -append -file [tim_file compromisos.rpt]
    }
}

set f [open [tim_file resumen.txt] w]
puts $f [join $resumen "\n"]
close $f
puts [join $resumen "\n"]
puts "\nReportes en $tim_dir"
