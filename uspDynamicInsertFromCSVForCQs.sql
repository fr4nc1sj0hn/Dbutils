/**
	Summary:
		Takes a cq csv file and loads it into a table specified in the input
	Example:
		EXEC dbo.uspDynamicInsertFromCSVForCQs
			@TargetTableName	= 'CQ1',
			@TargetSchemaName	= 'staging',
			@Folderpath			= 'C:\RawFiles\Amro\2017\Coding\',
			@FileName			= 'CQ1.csv'
	Returns: None

	Requirements:
		1. Turn on 'Ad Hoc Distributed Queries'
		2. Install 64-bit ODBC text driver
			https://www.microsoft.com/en-us/download/details.aspx?id=13255
	
	Change History
	==============================================================
	11/02/2021	FRANC583	Initial Version (CPI-6660)
**/
CREATE PROCEDURE [dbo].[uspDynamicInsertFromCSVForCQs]
	@TargetTableName	NVARCHAR(100),
	@TargetSchemaName	NVARCHAR(50) ,
	@Folderpath			NVARCHAR(500),
	@FileName			NVARCHAR(100),
	@Debug				BIT = 0
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @Staging NVARCHAR(100) = QUOTENAME(@TargetSchemaName) + '.' + QUOTENAME(@TargetTableName + N'_Temp');
	DECLARE @SQL NVARCHAR(MAX) = '';

	DECLARE @TempTable NVARCHAR(100) = @TargetTableName + '_Temp';

	DECLARE @altercolumns NVARCHAR(MAX) = N'';


	SET @SQL = '
		IF OBJECT_ID(N''' + @Staging + ''') IS NOT NULL
			DROP TABLE ' + @Staging + ';
		SELECT TOP 1 * INTO ' + @Staging + '
		FROM OPENROWSET		
		(	
			''MSDASQL'', 
			''Driver={Microsoft Access Text Driver (*.txt, *.csv)};IMEX=1;DBQ=' + @Folderpath + ''', 
			''SELECT * FROM ' + @FileName + '''
		);
		';

	PRINT @SQL
	EXEC sp_executesql @SQL;
	SET @TargetTableName = @TargetTableName + N'';

	SELECT @altercolumns = @altercolumns + '
	ALTER TABLE ' + @Staging + '
	ALTER COLUMN ' + QUOTENAME(ColumnName) + ' NVARCHAR(2000);'
	FROM dbo.tvfGetColumns(@TempTable,@TargetSchemaName);

	SET @SQL = '
	TRUNCATE TABLE ' + @Staging + ';
	' + @altercolumns + ';';

	PRINT @SQL;

	EXEC sp_executesql @SQL;

	-- Insert ALL the data now
	SET @SQL = '	
		INSERT INTO ' + @Staging + '
		SELECT  * 
		FROM OPENROWSET		
		(	
			''MSDASQL'', 
			''Driver={Microsoft Access Text Driver (*.txt, *.csv)};DBQ=' + @Folderpath + ''', 
			''SELECT * FROM ' + @FileName + '''
		);';

	EXEC sp_executesql @SQL;

	DECLARE 
		@select NVARCHAR(MAX) = N'',
		@cteSelect NVARCHAR(MAX) = N''

	SELECT @cteSelect = @cteSelect + 
		QUOTENAME(ColumnName) + N' = ' 
		+ IIF(ColumnName LIKE 'Level%',
			'IIF(CHARINDEX(''|Level'',' + QUOTENAME(ColumnName) + N') = 0,' + QUOTENAME(ColumnName) + N',LEFT(' + QUOTENAME(ColumnName) + N',CHARINDEX(''|Level'',' + QUOTENAME(ColumnName) + N') - 1))',
			QUOTENAME(ColumnName)) + N',
		'
	FROM  dbo.tvfGetColumns(@TempTable,@TargetSchemaName)

	SET @cteSelect = LEFT(@cteSelect,LEN(@cteSelect) - 5)

	SELECT @select = @select + 
		CASE 
			WHEN (ColumnName = 'Level 2')
				THEN '[Level 2] = [Level 2] + ''|'' + [Level 1],'
			WHEN (ColumnName = 'Level 3')
				THEN '[Level 3] = [Level 3] + ''|'' + [Level 2] + ''|'' + [Level 1],'
			WHEN (ColumnName = 'Level 4')
				THEN '[Level 4] = [Level 4] + ''|'' + [Level 3] + ''|'' + [Level 2] + ''|'' + [Level 1],'
			WHEN (ColumnName = 'Level 5')
				THEN '[Level 5] = [Level 5] + ''|'' + [Level 4] + ''|'' + [Level 3] + ''|'' + [Level 2] + ''|'' + [Level 1],'
			WHEN (ColumnName = 'Level 6')
				THEN '[Level 6] = [Level 6] + ''|'' + [Level 5] + ''|'' + [Level 4] + ''|'' + [Level 3] + ''|'' + [Level 2] + ''|'' + [Level 1],'

			WHEN (ColumnName LIKE 'Level%' AND ColumnName NOT IN ('Level 1','Level 2','Level 3','Level 4','Level 5','Level 6'))
				THEN QUOTENAME(ColumnName) + N' = ' 
					+ QUOTENAME(ColumnName) + N' 
					+ ''|'' + [Level ' + CAST(([Level] - 1) AS NVARCHAR(3)) + N'] 
					+ ''|'' + [Level ' + CAST(([Level] - 2) AS NVARCHAR(3)) + N'] 
					+ ''|'' + [Level ' + CAST(([Level] - 3) AS NVARCHAR(3)) + N']
					+ ''|'' + [Level ' + CAST(([Level] - 4) AS NVARCHAR(3)) + N']
					+ ''|'' + [Level ' + CAST(([Level] - 5) AS NVARCHAR(3)) + N'],'
			ELSE QUOTENAME(ColumnName) + N' = ' + QUOTENAME(ColumnName) + N','
		END
	FROM
	(
		SELECT *,IIF(ColumnName LIKE 'Level%',REPLACE(ColumnName,'Level ',''),0) AS [Level] 
		FROM  dbo.tvfGetColumns(@TempTable,@TargetSchemaName)
	)A
	SET @select = LEFT(@select,LEN(@select) - 1)

	PRINT @select
	DECLARE @CQTable NVARCHAR(200) =  QUOTENAME(@TargetSchemaName) + '.' + QUOTENAME(@TargetTableName);

	SET @SQL = N'
		DROP TABLE IF EXISTS ' + @CQTable + N'
		;WITH cte AS
		(
			SELECT  ' + @cteSelect + N' 
			FROM ' + @Staging + N'
		)
		SELECT 
		' + @select + N'
		INTO ' + @CQTable + N'
		FROM cte;'

	--PRINT @SQL
	EXEC sp_executesql @SQL;

	SELECT @altercolumns = @altercolumns + '
	ALTER TABLE ' + @CQTable + '
	ALTER COLUMN ' + QUOTENAME(ColumnName) + ' NVARCHAR(2000);'
	FROM dbo.tvfGetColumns(@TargetTableName,@TargetSchemaName);

	EXEC sp_executesql @altercolumns;

	DECLARE @drop NVARCHAR(MAX) = N'
	DROP TABLE IF EXISTS ' + @Staging;

	EXEC sp_executesql @drop;


END
GO
