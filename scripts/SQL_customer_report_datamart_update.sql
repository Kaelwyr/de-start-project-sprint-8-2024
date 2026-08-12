-- DDL витрины данных
DROP TABLE IF EXISTS dwh.customer_report_datamart;
CREATE TABLE dwh.customer_report_datamart (
	id BIGINT GENERATED ALWAYS AS IDENTITY NOT null,-- идентификатор записи;
	customer_id BIGINT NOT null, 					-- идентификатор заказчика;
	customer_name VARCHAR NOT null, 				-- Ф. И. О. заказчика;
	customer_address VARCHAR NOT null, 				-- адрес заказчика;
	customer_birthday DATE NOT null, 				-- дата рождения заказчика;
	customer_email VARCHAR NOT null, 				-- электронная почта заказчика;
	customer_money NUMERIC(15,2) NOT null,			-- сумма, которую потратил заказчик;
	platform_money BIGINT NOT null,					-- сумма, которую заработала платформа от покупок заказчика за месяц (10% от суммы, которую потратил заказчик);
	count_order BIGINT NOT null, 					-- количество заказов у заказчика за месяц;
	avg_price_order NUMERIC(10,2) NOT null, 		-- средняя стоимость одного заказа у заказчика за месяц;
	median_time_order_completed NUMERIC(10,1), 		-- медианное время в днях от момента создания заказа до его завершения за месяц;
	top_product_category VARCHAR NOT null, 			-- самая популярная категория товаров у этого заказчика за месяц;
	top_master VARCHAR NOT null, 					-- идентификатор самого популярного мастера ручной работы у заказчика. Если заказчик сделал одинаковое количество заказов у нескольких мастеров, то берется любой мастер;
	count_order_created BIGINT NOT null, 			-- количество созданных заказов за месяц
	count_order_in_progress BIGINT NOT null, 		-- количество заказов в процессе изготовки за месяц 
	count_order_delivery BIGINT NOT null, 			-- количество заказов в доставке за месяц 
	count_order_done BIGINT NOT null, 				-- количество завершённых заказов за месяц 
	count_order_not_done BIGINT NOT null, 			-- количество незавершённых заказов за месяц 
	report_period VARCHAR NOT null, 				-- отчётный период год и месяц
	load_dttm timestamp NOT null, 					-- Дата и время загрузки данных
	CONSTRAINT customer_report_datamart_pk PRIMARY KEY (id)
);

-- DDL таблицы инкрементальных загрузок
DROP TABLE IF EXISTS dwh.load_dates_customer_report_datamart;

CREATE TABLE IF NOT EXISTS dwh.load_dates_customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    load_dttm DATE NOT NULL,
    CONSTRAINT load_dates_customer_report_datamart_pk PRIMARY KEY (id)
);

WITH
dwh_delta AS ( -- определяем, какие данные были изменены в витрине или добавлены в DWH. Формируем дельту изменений
    SELECT
            dc.customer_id AS customer_id,
            dc.customer_name AS customer_name,
            dc.customer_address AS customer_address,
            dc.customer_birthday AS customer_birthday,
            dc.customer_email AS customer_email,
            fo.order_id AS order_id,
            dp.product_id AS product_id,
            dp.product_price AS product_price,
            dp.product_type AS product_type,
            fo.craftsman_id AS craftsman_id,
            fo.order_completion_date - fo.order_created_date AS diff_order_date, 
            fo.order_status AS order_status,
            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period,
            crd.customer_id AS exist_customer_id,
            dc.load_dttm AS customer_load_dttm,
            dcs.load_dttm AS craftsman_load_dttm,
            dp.load_dttm AS products_load_dttm
            FROM dwh.f_order fo 
                INNER JOIN dwh.d_customer dc ON fo.customer_id = dc.customer_id
                INNER JOIN dwh.d_craftsman dcs ON fo.craftsman_id = dcs.craftsman_id
                INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
                LEFT JOIN dwh.customer_report_datamart crd ON dc.customer_id = crd.customer_id AND crd.report_period = TO_CHAR(fo.order_created_date, 'yyyy-mm')
                    WHERE (fo.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart)) OR
                            (dc.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart)) OR
                            (dcs.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart)) OR
                            (dp.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart))
),
dwh_update_delta AS ( -- делаем выборку заказчиков, по которым были изменения в DWH. По этим мастерам данные в витрине нужно будет обновить
    SELECT     
            dd.exist_customer_id AS customer_id
            FROM dwh_delta dd 
                WHERE dd.exist_customer_id IS NOT NULL        
),
dwh_delta_insert_result AS ( -- делаем расчёт витрины по новым данным. Этой информации по заказчикам в рамках расчётного периода раньше не было, это новые данные. Их можно просто вставить (insert) в витрину без обновления
    SELECT  
            T4.customer_id AS customer_id,
            T4.customer_name AS customer_name,
            T4.customer_address AS customer_address,
            T4.customer_birthday AS customer_birthday,
            T4.customer_email AS customer_email,
            T4.customer_money AS customer_money,
            T4.platform_money AS platform_money,
            T4.count_order AS count_order,
            T4.avg_price_order AS avg_price_order,
            T4.product_type AS top_product_category,
            COALESCE(T6.craftsman_name, '') AS top_master,
            T4.median_time_order_completed AS median_time_order_completed,
            T4.count_order_created AS count_order_created,
            T4.count_order_in_progress AS count_order_in_progress,
            T4.count_order_delivery AS count_order_delivery,
            T4.count_order_done AS count_order_done,
            T4.count_order_not_done AS count_order_not_done,
            T4.report_period AS report_period,
           	T4.load_dttm
            FROM (
                SELECT     -- в этой выборке объединяем две внутренние выборки по расчёту столбцов витрины и применяем оконную функцию для определения самой популярной категории товаров
                        *,
                        RANK() OVER(PARTITION BY T2.customer_id ORDER BY count_product DESC) AS rank_count_product 
                        FROM ( 
                            SELECT -- в этой выборке делаем расчёт по большинству столбцов, так как все они требуют одной и той же группировки, кроме столбца с самой популярной категорией товаров у заказчика. Для этого столбца сделаем отдельную выборку с другой группировкой и выполним JOIN
                                T1.customer_id AS customer_id,
                                T1.customer_name AS customer_name,
                                T1.customer_address AS customer_address,
                                T1.customer_birthday AS customer_birthday,
                                T1.customer_email AS customer_email,
                                SUM(T1.product_price) - (SUM(T1.product_price) * 0.1) AS customer_money,
                                SUM(T1.product_price) * 0.1 AS platform_money,
                                COUNT(order_id) AS count_order,
                                AVG(T1.product_price) AS avg_price_order,
                                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
                                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress, 
                                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery, 
                                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done, 
                                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                T1.report_period AS report_period,
                                GREATEST(COALESCE(MAX(T1.customer_load_dttm), NOW()), 
                    				COALESCE(MAX(T1.craftsman_load_dttm), NOW()), 
                    				COALESCE(MAX(T1.products_load_dttm), NOW())
                    				) as load_dttm
                                FROM dwh_delta AS T1
                                    WHERE T1.exist_customer_id IS NULL
                                        GROUP BY T1.customer_id, T1.customer_name, T1.customer_address, T1.customer_birthday, T1.customer_email, T1.report_period
                            ) AS T2 
                                INNER JOIN (
                                    SELECT     -- Эта выборка поможет определить самый популярный товар у заказчика. Эта выборка не делается в предыдущем запросе, так как нужна другая группировка. Для данных этой выборки можно применить оконную функцию, которая и покажет самую популярную категорию товаров у заказчика
                                            dd.customer_id AS customer_id_for_product_type, 
                                            dd.product_type, 
                                            COUNT(dd.product_id) AS count_product
                                            FROM dwh_delta AS dd
                                                GROUP BY dd.customer_id, dd.product_type
                                                    ORDER BY count_product DESC) AS T3 ON T2.customer_id = T3.customer_id_for_product_type
                ) AS T4 
                left join ( -- Это выборка популярного мастера у заказчика
                	select 
                		T5.customer_id,
	                	T5.report_period,
	                	T5.craftsman_name,
                		row_number() over (partition by T5.customer_id, T5.report_period order by T5.cnt desc, T5.craftsman_id) as rn
                	from (
	                	select 
	                		dd.customer_id,
	                		dd.report_period,
	                		dd.craftsman_id,
	                		dcs.craftsman_name,
	                		count(*) as cnt
	            		from dwh_delta dd
	            			inner join dwh.d_craftsman dcs on dd.craftsman_id = dcs.craftsman_id 
	            		where dd.exist_customer_id is null
	            		group by dd.customer_id, dd.report_period, dd.craftsman_id, dcs.craftsman_name
	        			) as T5
            	) as T6 ON T4.customer_id = T6.customer_id 
	        				and T4.report_period = T6.report_period 
	        				and T6.rn = 1
    			where T4.rank_count_product = 1
            	ORDER BY report_period
),
dwh_delta_update_result AS ( -- делаем перерасчёт для существующих записей витрины, так как данные обновились за отчётные периоды. Логика похожа на insert, но нужно достать конкретные данные из DWH
    SELECT 
            T4.customer_id AS customer_id,
            T4.customer_name AS customer_name,
            T4.customer_address AS customer_address,
            T4.customer_birthday AS customer_birthday,
            T4.customer_email AS customer_email,
            T4.customer_money AS customer_money,
            T4.platform_money AS platform_money,
            T4.count_order AS count_order,
            T4.avg_price_order AS avg_price_order,
            T4.product_type AS top_product_category,
            T4.median_time_order_completed AS median_time_order_completed,
            COALESCE(T6.craftsman_name, '') AS top_master,
            T4.count_order_created AS count_order_created,
            T4.count_order_in_progress AS count_order_in_progress,
            T4.count_order_delivery AS count_order_delivery, 
            T4.count_order_done AS count_order_done, 
            T4.count_order_not_done AS count_order_not_done,
            T4.report_period AS report_period,
			T4.load_dttm
            FROM (
                SELECT     -- в этой выборке объединяем две внутренние выборки по расчёту столбцов витрины и применяем оконную функцию для определения самой популярной категории товаров
                        *,
                        RANK() OVER(PARTITION BY T2.customer_id ORDER BY count_product DESC) AS rank_count_product 
                        FROM (
                            SELECT -- в этой выборке делаем расчёт по большинству столбцов, так как все они требуют одной и той же группировки, кроме столбца с самой популярной категорией товаров у заказчика. Для этого столбца сделаем отдельную выборку с другой группировкой и выполним JOIN
                                T1.customer_id AS customer_id,
                                T1.customer_name AS customer_name,
                                T1.customer_address AS customer_address,
                                T1.customer_birthday AS customer_birthday,
                                T1.customer_email AS customer_email,
                                SUM(T1.product_price) - (SUM(T1.product_price) * 0.1) AS customer_money,
                                SUM(T1.product_price) * 0.1 AS platform_money,
                                COUNT(order_id) AS count_order,
                                AVG(T1.product_price) AS avg_price_order,
                                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created, 
                                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress, 
                                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery, 
                                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done, 
                                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                T1.report_period AS report_period,
                                GREATEST(COALESCE(MAX(T1.customer_load_dttm), NOW()),
									COALESCE(MAX(T1.craftsman_load_dttm), NOW()), 
									COALESCE(MAX(T1.products_load_dttm), NOW())
									) as load_dttm
                                FROM (
                                    SELECT     -- в этой выборке достаём из DWH обновлённые или новые данные по заказчикам, которые уже есть в витрине
                                            dc.customer_id AS customer_id,
                                            dc.customer_name AS customer_name,
                                            dc.customer_address AS customer_address,
                                            dc.customer_birthday AS customer_birthday,
                                            dc.customer_email AS customer_email,
                                            fo.order_id AS order_id,
                                            dp.product_id AS product_id,
                                            dp.product_price AS product_price,
                                            dp.product_type AS product_type,
                                            fo.order_completion_date - fo.order_created_date AS diff_order_date,
                                            fo.order_status AS order_status, 
                                            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period,
                                            dc.load_dttm AS customer_load_dttm,
								            dcs.load_dttm AS craftsman_load_dttm,
								            dp.load_dttm AS products_load_dttm
                                        FROM dwh.f_order fo 
                                            INNER JOIN dwh.d_customer dc ON fo.customer_id = dc.customer_id 
                                            INNER JOIN dwh.d_craftsman dcs ON fo.craftsman_id = dcs.craftsman_id 
                                            INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
                                            INNER JOIN dwh_update_delta ud ON fo.customer_id = ud.customer_id
                                ) AS T1
                                GROUP BY T1.customer_id, T1.customer_name, T1.customer_address, T1.customer_birthday, T1.customer_email, T1.report_period
                            ) AS T2 
                                INNER JOIN (
                                    SELECT     -- Эта выборка поможет определить самый популярный товар у заказчика за месяц. Эта выборка не делается в предыдущем запросе, так как нужна другая группировка. Для данных этой выборки можно применить оконную функцию, которая и покажет самую популярную категорию товаров у заказчика
                                        dd.customer_id AS customer_id_for_product_type, 
                                        dd.product_type, 
                                        COUNT(dd.product_id) AS count_product
                                    FROM dwh_delta AS dd
                                    GROUP BY dd.customer_id, dd.product_type
                                    ORDER BY count_product DESC) AS T3 ON T2.customer_id = T3.customer_id_for_product_type
			                ) AS T4
			                left join ( -- Это выборка популярного мастера у заказчика
			                	SELECT 
			                		customer_id,
				                	report_period,
				                	craftsman_name,
			                		row_number() over (partition by customer_id, report_period order by cnt desc, craftsman_id) as rn
			                	from (
				                	SELECT 
				                		dc.customer_id,
				                		TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period,
				                		fo.craftsman_id,
				                		dcs.craftsman_name,
				                		count(*) as cnt
				            		FROM dwh.f_order fo
							            INNER JOIN dwh.d_customer dc ON fo.customer_id = dc.customer_id
							            INNER JOIN dwh.d_craftsman dcs ON fo.craftsman_id = dcs.craftsman_id
							            INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
							            INNER JOIN dwh_update_delta ud ON fo.customer_id = ud.customer_id
						            GROUP BY dc.customer_id, report_period, fo.craftsman_id, dcs.craftsman_name
			        			) as T5
			            	) as T6 ON T4.customer_id = T6.customer_id 
				        				and T4.report_period = T6.report_period 
				        				and T6.rn = 1
			    			where T4.rank_count_product = 1
			            	ORDER BY report_period
),
insert_delta AS ( -- выполняем insert новых расчитанных данных для витрины 
    INSERT INTO dwh.customer_report_datamart (
        customer_id,
        customer_name,
        customer_address,
        customer_birthday, 
        customer_email, 
        customer_money, 
        platform_money, 
        count_order, 
        avg_price_order,
        median_time_order_completed,
        top_product_category, 
        top_master,
        count_order_created, 
        count_order_in_progress, 
        count_order_delivery, 
        count_order_done, 
        count_order_not_done, 
        report_period,
        load_dttm
    ) SELECT 
	        customer_id,
	        customer_name,
	        customer_address,
	        customer_birthday, 
	        customer_email, 
	        customer_money, 
	        platform_money, 
	        count_order, 
	        avg_price_order,
	        median_time_order_completed,
	        top_product_category, 
	        top_master,
	        count_order_created, 
	        count_order_in_progress, 
	        count_order_delivery, 
	        count_order_done, 
	        count_order_not_done, 
	        report_period,
	        load_dttm
        FROM dwh_delta_insert_result
),
update_delta AS ( -- выполняем обновление показателей в отчёте по уже существующим заказчикам
    UPDATE dwh.customer_report_datamart SET
        customer_name = updates.customer_name, 
        customer_address = updates.customer_address, 
        customer_birthday = updates.customer_birthday, 
        customer_email = updates.customer_email, 
        customer_money = updates.customer_money, 
        platform_money = updates.platform_money, 
        count_order = updates.count_order, 
        avg_price_order = updates.avg_price_order, 
        median_time_order_completed = updates.median_time_order_completed, 
        top_product_category = updates.top_product_category,
        top_master = updates.top_master,
        count_order_created = updates.count_order_created, 
        count_order_in_progress = updates.count_order_in_progress, 
        count_order_delivery = updates.count_order_delivery, 
        count_order_done = updates.count_order_done,
        count_order_not_done = updates.count_order_not_done, 
        report_period = updates.report_period,
        load_dttm = updates.load_dttm
    FROM (
        SELECT 
            customer_id,
            customer_name,
            customer_address,
            customer_birthday,
            customer_email,
            customer_money,
            platform_money,
            count_order,
            avg_price_order,
            median_time_order_completed,
            top_product_category,
            top_master,
            count_order_created,
            count_order_in_progress,
            count_order_delivery,
            count_order_done,
            count_order_not_done,
            report_period,
            load_dttm
        FROM dwh_delta_update_result) AS updates
    WHERE dwh.customer_report_datamart.customer_id = updates.customer_id
		AND dwh.customer_report_datamart.report_period = updates.report_period
),
insert_load_date AS ( -- делаем запись в таблицу загрузок о том, когда была совершена загрузка, чтобы в следующий раз взять данные, которые будут добавлены или изменены после этой даты
    INSERT INTO dwh.load_dates_customer_report_datamart (load_dttm)
    SELECT GREATEST(COALESCE(MAX(customer_load_dttm), NOW()), 
                    COALESCE(MAX(craftsman_load_dttm), NOW()), 
                    COALESCE(MAX(products_load_dttm), NOW())) 
        FROM dwh_delta
)
SELECT 'increment datamart'; -- инициализируем запрос CTE