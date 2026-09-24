*&---------------------------------------------------------------------*
*& Report  ZGIT_SPOOL_SEARCH_STRING
*&
*&---------------------------------------------------------------------*
*&
*&
*&---------------------------------------------------------------------*
report zgit_spool_search_string.

tables: tbtco, tbtcp.

select-options: s_jobnam for tbtco-jobname obligatory,
                s_sdlstr for tbtco-sdlstrtdt obligatory, " Fecha de inicio planificada
                s_prog   for tbtcp-progname,            " Report/Programa del paso
                s_auth   for tbtco-authcknam.           " Creador del Job
selection-screen: skip.
selection-screen: begin of line,
  comment 14(14) text-cas,
  comment 29(20) text-exp,
  end of line.

selection-screen: begin of line,
comment 1(12) text-p01.
selection-screen: position 19.
parameters p_case1  as checkbox.
selection-screen: position 35.
parameters p_regex1 as checkbox.
selection-screen: position 50.
parameters p_string type string lower case.
selection-screen: end of line.
parameters: p_rfcdst type rfcdest no-display.

types: begin of ty_job,
         jobname  type tbtco-jobname,
         jobcount type tbtco-jobcount,
       end of ty_job,

       begin of ty_job_spool,
         jobname   type tbtco-jobname,
         jobcount  type tbtco-jobcount,
         listident type tbtcp-listident,
         progname  type tbtcp-progname,
         line      type char1024,
       end of ty_job_spool.

data: gt_jobs_ok    type standard table of ty_job_spool ##NEEDED.

start-of-selection.
  perform buscar_en_spool.

end-of-selection.
  perform mostrar_listado.

*&---------------------------------------------------------------------*
*& Form buscar_en_spool
*&---------------------------------------------------------------------*
form buscar_en_spool.

  data: lt_tbtco      type standard table of ty_job,
        lt_jobs       type standard table of ty_job_spool,
        lt_spool_rows type standard table of char255,
        lv_spool_text type string,
        lv_match      type abap_bool,
        lo_regex      type ref to cl_abap_regex,
        lo_matcher    type ref to cl_abap_matcher.

  " 1. Buscar los pasos de Jobs que generaron Spool y cumplen los filtros
  select j~jobname, j~jobcount, p~listident, p~progname
    from tbtco as j
    inner join tbtcp as p on j~jobname  = p~jobname
                         and j~jobcount = p~jobcount
    into corresponding fields of table @lt_jobs
    where j~jobname    in @s_jobnam
      and j~sdlstrtdt  in @s_sdlstr
      and j~authcknam  in @s_auth
      and p~progname   in @s_prog
      and p~listident  <> '0000000000'.

  if lt_jobs is initial.
    message e208(00) with 'No se encontraron Jobs con Spool para los criterios seleccionados.'  ##NO_TEXT.
    return.
  endif.

  if p_regex1 = abap_true.
    " Búsqueda con Expresión Regular
    try.
        if p_case1 = abap_false.
          create object lo_regex
            exporting
              pattern     = p_string
              ignore_case = abap_true.
        else.
          create object lo_regex
            exporting
              pattern     = p_string
              ignore_case = abap_false.
        endif.
      catch cx_sy_regex.
        message e208(00) with 'Error: Expresión regular inválida en los parámetros.'  ##NO_TEXT.
        return.
    endtry.
  else.
    if p_case1 eq abap_false.
      translate p_string to upper case.
    endif.
  endif.

  " 2. Procesar cada orden de Spool
  loop at lt_jobs into data(ls_job).
    clear: lt_spool_rows, lv_spool_text, lv_match.

    data(lv_spool_id) = conv rspoid( ls_job-listident ).

    " Leer el contenido del Spool ABAP de forma correcta
    call function 'RSPO_RETURN_ABAP_SPOOLJOB'
      exporting
        rqident = lv_spool_id
      tables
        buffer  = lt_spool_rows
      exceptions
        others  = 1.

    if sy-subrc <> 0.
      continue. " Si no es un spool ABAP o falla la lectura, salta al siguiente
    endif.

    " Convertir las líneas leídas en un único String continuo
*    lv_spool_text = concat_lines_of( table = lt_spool_rows sep = cl_abap_char_utilities=>newline ).

    loop at lt_spool_rows into lv_spool_text.

      " 3. Aplicar la lógica de búsqueda según los parámetros (Regex y Case-sensitive)
      if p_regex1 = abap_true.
        " Búsqueda con Expresión Regular
        try.
            lo_matcher = lo_regex->create_matcher( text = lv_spool_text ).
            if lo_matcher->match( ) = abap_true or lo_matcher->find_next( ) = abap_true.
              lv_match = abap_true.
            endif.
          catch cx_sy_regex.
            message e208(00) with 'Error: Expresión regular inválida en los parámetros.'  ##NO_TEXT.
            return.
        endtry.
      else.
        " Búsqueda de texto Normal
        if p_case1 = abap_false.
          " Case-insensitive
          translate lv_spool_text to upper case.
        endif.
        if lv_spool_text cs p_string.
          lv_match = abap_true.
        endif.
      endif.

      " 4. Mostrar si hubo coincidencia
      if lv_match = abap_true.
        ls_job-line = lv_spool_text.
        append ls_job to gt_jobs_ok.
        clear lv_match.
      endif.
    endloop.
  endloop.
endform.

*-----------------
* class definition
*
class lcl_handle_events definition.
  public section.
    methods:
      on_link_click   for event link_click of
                  cl_salv_events_table
        importing row column.
endclass.                    "lcl_handle_events DEFINITION
*---------------------
* class implimentation
*
class lcl_handle_events implementation.
  method on_link_click.
    read table gt_jobs_ok into data(ls_job) index row.
    if sy-subrc ne 0. return. endif.
    case column.
      when 'LISTIDENT'.
        perform visualizar using ls_job-listident.
      when 'LINE'.
        perform visualizar_linea using ls_job-line.
    endcase.
  endmethod.                    "on_link_click
endclass.                    "lcl_handle_events IMPLEMENTATION
*&---------------------------------------------------------------------*
*&      Form  MOSTRAR_LISTADO
*&---------------------------------------------------------------------*
*       text
*----------------------------------------------------------------------*
*  -->  p1        text
*  <--  p2        text
*----------------------------------------------------------------------*
form mostrar_listado .
  data: lo_alv type ref to cl_salv_table.
  data lo_column type ref to cl_salv_column_table.

  try.
      cl_salv_table=>factory(
          importing
          r_salv_table = lo_alv
          changing
          t_table      = gt_jobs_ok[] ).

      data(lo_functions) = lo_alv->get_functions( ).
      lo_functions->set_all( abap_true ).

*     Configuración de columnas
      data(lo_columns) = lo_alv->get_columns( ).
      lo_columns->set_optimize( abap_true ).
      lo_column ?= lo_columns->get_column( 'LISTIDENT' ).
      lo_column->set_cell_type( if_salv_c_cell_type=>hotspot ).
      lo_column ?= lo_columns->get_column( 'LINE' ).
      lo_column->set_cell_type( if_salv_c_cell_type=>hotspot ).

      data(lo_events) = lo_alv->get_event( ).
      data(lo_event_handler) = new  lcl_handle_events( ).
      set handler lo_event_handler->on_link_click for lo_events.

      lo_alv->display( ).

    catch cx_salv_msg cx_salv_not_found into data(lx_msg).
      message lx_msg type 'E'.
  endtry.
endform.
*&---------------------------------------------------------------------*
*&      Form  VISUALIZAR
*&---------------------------------------------------------------------*
*       text
*----------------------------------------------------------------------*
*      -->P_LS_JOB_LISTIDENT  text
*----------------------------------------------------------------------*
form visualizar  using    p_listident.
  data(lv_id_list) = value sp01r_id_list( ( id = p_listident ) ).
  call function 'RSPO_RID_SPOOLREQ_DISP'
    exporting
      id_list = lv_id_list.
endform.
*&---------------------------------------------------------------------*
*&      Form  VISUALIZAR_LINEA
*&---------------------------------------------------------------------*
*       text
*----------------------------------------------------------------------*
*      -->P_LS_JOB_LINE  text
*----------------------------------------------------------------------*
form visualizar_linea  using  p_line.
  cl_demo_output=>display( p_line ).
endform.
