/**
	Summary:
		DROP Tenant Database
	Example:
		EXEC dbo.uspDeleteTenant
			@TenantDatabaseName = 'EES_GENGAR_DW';

	Returns: None
	
	Change History
	==============================================================
	8/22/2018	FRANC583	Initial Version, CPA-265
	3/4/2019	FRANC583	CPA-654
**/
CREATE PROCEDURE [dbo].[uspDeleteTenant]
	@TenantDatabaseName NVARCHAR(200),
	@Verbose			BIT = 0
AS
BEGIN
	DECLARE 
		@query		NVARCHAR(2000);

	IF EXISTS(SELECT * FROM sysdatabases WHERE name = @TenantDatabaseName)
	BEGIN
		SET @query = '
		ALTER DATABASE ' +  @TenantDatabaseName + ' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
		DROP DATABASE ' + @TenantDatabaseName;

		IF @Verbose = 1 
			PRINT 'Executing query : ' + @query;

		EXEC sp_executesql @query;
	END

	-- Delete AS Database

	EXEC [xmla].[uspDeleteOLAPDatabase] @DatabaseName = @TenantDatabaseName;

	DECLARE @Job_Name NVARCHAR(200) = 'Opinion Survey DW ETL ' + @TenantDatabaseName;
	DECLARE @Job_Name_backup NVARCHAR(200) = 'Backup ' + @TenantDatabaseName;

	IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs_view WHERE name = @Job_Name)
	BEGIN
		EXEC msdb.dbo.sp_delete_job 
				@job_name = @Job_Name, 
				@delete_unused_schedule = 1;
	END

	IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs_view WHERE name = @Job_Name_backup)
	BEGIN
		EXEC msdb.dbo.sp_delete_job 
				@job_name = @Job_Name_backup, 
				@delete_unused_schedule = 1;
	END

	EXEC dbo.uspDropLinkedServer @DBName = @TenantDatabaseName;
END;