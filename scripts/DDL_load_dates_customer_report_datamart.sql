-- dwh.load_dates_craftsman_report_datamart определение
DROP TABLE dwh.load_dates_customer_report_datamart;
create table dwh.load_dates_customer_report_datamart ( 
	id bigint generated always as identity not null,
	load_dttm date not null,
	constraint load_dates_customer_report_datamart_pk primary key (id)
);