/**
	Summary:
		Takes a csv file and loads it into a table specified in the input
	Example:
		EXEC dbo.uspDynamicInsertFromCSV
			@TargetTableName	= 'CodingResponse',
			@TargetSchemaName	= 'staging',
			@Folderpath			= 'C:\RawFiles\Amro\2017\Coding\',
			@FileName			= 'CodingSurvey.csv'
	Returns: None

	Requirements:
		1. Turn on 'Ad Hoc Distributed Queries'
		2. Install 64-bit ODBC text driver
			https://www.microsoft.com/en-us/download/details.aspx?id=13255
	
	Change History
	==============================================================
	3/15/2018	FRANC583	Initial Version
	3/28/2019	FRANC583	CPA-674
**/
CREATE PROCEDURE dbo.uspDynamicInsertFromCSV
	@TargetTableName	NVARCHAR(100),
	@TargetSchemaName	NVARCHAR(50) ,
	@Folderpath			NVARCHAR(500),
	@FileName			NVARCHAR(100),
	@Debug				BIT = 0
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @Staging NVARCHAR(100) = QUOTENAME(@TargetSchemaName) + '.' + QUOTENAME(@TargetTableName);
	DECLARE @SQL NVARCHAR(MAX) = '';
	
	DECLARE @altercolumns NVARCHAR(MAX) = N'';

	-- Infer the Data Types first
	SET @SQL = '
		IF OBJECT_ID(N''' + @Staging + ''') IS NOT NULL
			DROP TABLE ' + @Staging + ';
		SELECT TOP 1 * INTO ' + @Staging + '
		FROM OPENROWSET		
		(	
			''MSDASQL'', 
			''Driver={Microsoft Access Text Driver (*.txt, *.csv)};DBQ=' + @Folderpath + ''', 
			''SELECT * FROM ' + @FileName + '''
		);
		';
	
	EXEC sp_executesql @SQL;

	-- Force conversion to NVARCHAR
	SELECT @altercolumns = @altercolumns + '
	ALTER TABLE ' + @Staging + '
	ALTER COLUMN ' + QUOTENAME(ColumnName) + ' NVARCHAR(2000);'
	FROM dbo.tvfGetColumns(@TargetTableName,@TargetSchemaName);

	SET @SQL = '
	TRUNCATE TABLE ' + @Staging + ';
	' + @altercolumns + ';';

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
END
