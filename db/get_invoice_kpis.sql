create or replace function get_invoice_kpis(
    p_page_id          in number,
    p_region_static_id in varchar2
) return t_kpi_tab pipelined
is
  -- KPIs over LANDING_APEX_UPLOAD, honoring the region's current filters
  -- (IR filters/search when the region is an Interactive Report).
  l_region_id     number;
  l_source_type   apex_application_page_regions.source_type%type;
  l_component_id  number := null;
  l_ctx           apex_exec.t_context;

  l_invoices      number := 0;
  l_total_amount  number := 0;
  l_avg_invoice   number := 0;
  l_max_invoice   number := 0;
  l_vendors       number := 0;
  l_avg_gl_days   number := 0;

  function fmt_num(p number) return varchar2 is
  begin
    return to_char(nvl(p,0), 'FM999G999G999G990');
  end;

  -- $162.7B / $25.0M / $12,345
  function fmt_money(p number) return varchar2 is
  begin
    return case
             when nvl(p,0) >= 1e9 then '$' || to_char(p / 1e9, 'FM999G990D0') || 'B'
             when nvl(p,0) >= 1e6 then '$' || to_char(p / 1e6, 'FM999G990D0') || 'M'
             else '$' || to_char(nvl(p,0), 'FM999G999G990')
           end;
  end;
begin
  select region_id, source_type
    into l_region_id, l_source_type
    from apex_application_page_regions
   where application_id = v('APP_ID')
     and page_id        = p_page_id
     and static_id      = p_region_static_id;

  if upper(l_source_type) like '%INTERACTIVE REPORT%' then
    begin
      l_component_id := apex_ir.get_last_viewed_report_id(
                          p_page_id   => p_page_id,
                          p_region_id => l_region_id );
    exception
      when others then
        l_component_id := null;
    end;
  end if;

  l_ctx := apex_region.open_query_context(
             p_page_id      => p_page_id,
             p_region_id    => l_region_id,
             p_component_id => l_component_id,
             p_outer_sql    => q'[
               select
                 count(*)                       as invoices,
                 sum(invoice_amount)            as total_amount,
                 avg(invoice_amount)            as avg_invoice,
                 max(invoice_amount)            as max_invoice,
                 count(distinct vendor_num)     as vendors,
                 avg(gl_date - invoice_date)    as avg_gl_days
               from #APEX$SOURCE_DATA#
             ]'
           );

  if apex_exec.next_row(l_ctx) then
    l_invoices     := nvl(apex_exec.get_number(l_ctx, apex_exec.get_column_position(l_ctx, 'INVOICES')), 0);
    l_total_amount := nvl(apex_exec.get_number(l_ctx, apex_exec.get_column_position(l_ctx, 'TOTAL_AMOUNT')), 0);
    l_avg_invoice  := nvl(apex_exec.get_number(l_ctx, apex_exec.get_column_position(l_ctx, 'AVG_INVOICE')), 0);
    l_max_invoice  := nvl(apex_exec.get_number(l_ctx, apex_exec.get_column_position(l_ctx, 'MAX_INVOICE')), 0);
    l_vendors      := nvl(apex_exec.get_number(l_ctx, apex_exec.get_column_position(l_ctx, 'VENDORS')), 0);
    l_avg_gl_days  := nvl(apex_exec.get_number(l_ctx, apex_exec.get_column_position(l_ctx, 'AVG_GL_DAYS')), 0);
  end if;

  apex_exec.close(l_ctx);

  pipe row(t_kpi_row('INVOICES', 'Invoices',       fmt_num(l_invoices),        'fa fa-file-text-o', 'kpi-card u-color-1-border',  10));
  pipe row(t_kpi_row('SPEND',    'Total Spend',    fmt_money(l_total_amount),  'fa fa-usd',         'kpi-card u-color-4-border',  20));
  pipe row(t_kpi_row('AVG',      'Avg Invoice',    '$' || to_char(l_avg_invoice, 'FM999G999G990D00'),
                                                                               'fa fa-calculator',  'kpi-card u-color-2-border',  30));
  pipe row(t_kpi_row('MAX',      'Largest Invoice','$' || to_char(l_max_invoice, 'FM999G999G990D00'),
                                                                               'fa fa-arrow-up',    'kpi-card u-color-9-border',  40));
  pipe row(t_kpi_row('VENDORS',  'Vendors',        fmt_num(l_vendors),         'fa fa-building-o',  'kpi-card u-color-3-border',  50));
  pipe row(t_kpi_row('GLDAYS',   'Avg Days to GL', to_char(l_avg_gl_days, 'FM990D0') || ' days',
                                                                               'fa fa-clock-o',     'kpi-card u-color-6-border',  60));

  return;

exception
  when no_data_needed then
    apex_exec.close(l_ctx);
    return;
  when others then
    apex_exec.close(l_ctx);
    raise;
end;
/
