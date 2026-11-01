# ---------------------------------------------------------------------------
# Ondas de pipeline_tb para el informe (I-38): lanza la simulación de un programa
# y agrega, por etapa, el PC, los campos principales de cada registro de
# segmentación, la escritura del banco y halted. La captura va en
# docs/diagramas/ondas_<programa>.png.
#
#   python scripts/prep_tb.py sw/load_sin_dep_nops.s
#   y en la Tcl Console de Vivado (GUI):
#       set PROG load_sin_dep_nops            ;# opcional, es el de por defecto
#       source <ruta-al-repo>/scripts/ondas.tcl
#
# Usa el proyecto abierto o, si no hay ninguno, lo crea con create_project.tcl.
# La simulación se detiene 3 ciclos después de que sube halted. Antes del ciclo 1
# el banco carga imem por el puerto B (1024 ciclos con el core en reset): los
# marcadores quedan en el ciclo 1 y en el final, y entre los dos está la traza.
# En batch no hay ventana de ondas: solo comprueba que las señales existan.
# ---------------------------------------------------------------------------
if {![info exists PROG]} { set PROG load_sin_dep_nops }
set ond_root [file normalize [file join [file dirname [info script]] ..]]
set ond_dir  [file join $ond_root build tb $PROG]
if {![file exists [file join $ond_dir corte.hex]]} {
    error "No existe $ond_dir: corré antes python scripts/prep_tb.py sw/$PROG.s"
}

if {[catch {current_project}]} {
    source [file join $ond_root scripts create_project.tcl]
}
set_property top pipeline_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
set_property -name {xsim.simulate.xsim.more_options} \
    -value "-testplusarg DIR=$ond_dir" -objects [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]
launch_simulation

# Grupo y señales (radix hex salvo los bits sueltos y el número de ciclo)
set ond_ondas {
    {Banco}  {/pipeline_tb/tb_clk /pipeline_tb/tb_rst /pipeline_tb/tb_enable /pipeline_tb/ciclo}
    {IF}     {/pipeline_tb/u_dut/if_pc /pipeline_tb/u_dut/stop_fetch /pipeline_tb/u_dut/redirect}
    {IF/ID}  {/pipeline_tb/u_dut/if_id_valid /pipeline_tb/u_dut/if_id_pc /pipeline_tb/u_dut/if_id_instr}
    {ID/EX}  {/pipeline_tb/u_dut/id_ex_valid /pipeline_tb/u_dut/id_ex_pc /pipeline_tb/u_dut/id_ex_rd
              /pipeline_tb/u_dut/id_ex_rs1_data /pipeline_tb/u_dut/id_ex_rs2_data
              /pipeline_tb/u_dut/id_ex_imm /pipeline_tb/u_dut/id_ex_halt}
    {EX/MEM} {/pipeline_tb/u_dut/ex_mem_valid /pipeline_tb/u_dut/ex_mem_pc /pipeline_tb/u_dut/ex_mem_rd
              /pipeline_tb/u_dut/ex_mem_result /pipeline_tb/u_dut/ex_mem_store_data
              /pipeline_tb/u_dut/ex_mem_mem_write}
    {MEM/WB} {/pipeline_tb/u_dut/mem_wb_valid /pipeline_tb/u_dut/mem_wb_pc /pipeline_tb/u_dut/mem_wb_rd
              /pipeline_tb/u_dut/mem_wb_result /pipeline_tb/u_dut/mem_wb_read_data
              /pipeline_tb/u_dut/mem_wb_mem_to_reg}
    {WB}     {/pipeline_tb/u_dut/wb_reg_write /pipeline_tb/u_dut/wb_rd /pipeline_tb/u_dut/wb_data
              /pipeline_tb/u_dut/halted}
}
foreach {grupo senales} $ond_ondas {
    foreach s $senales {
        if {[llength [get_objects -quiet $s]] == 0} { error "ondas.tcl: no existe la señal $s" }
    }
}

set ond_gui [expr {$rdi::mode eq "gui"}]
if {$ond_gui} {
    create_wave_config ondas_$PROG
    foreach {grupo senales} $ond_ondas {
        add_wave_divider $grupo
        foreach s $senales {
            if {$s eq "/pipeline_tb/ciclo"} {
                add_wave -radix unsigned $s
            } else {
                add_wave -radix hex $s
            }
        }
    }
}

# Corre hasta el ciclo 1 y desde ahí hasta que sube halted, y 3 ciclos más
add_condition -name ond_c1 -notrace {/pipeline_tb/ciclo == 1} {stop}
run all
set ond_t0 [current_time]
remove_conditions ond_c1
add_condition -name ond_halt -notrace {/pipeline_tb/tb_o_halted == 1} {stop}
run all
remove_conditions ond_halt
run 30ns
set ond_t1 [current_time]
if {$ond_gui} {
    add_wave_marker $ond_t0
    add_wave_marker $ond_t1
}
puts "ondas.tcl: $PROG, traza entre $ond_t0 y $ond_t1 (zoom entre los marcadores)"
