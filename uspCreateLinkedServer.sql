/**
	Summary:
		Create a Linked Server targetting the local SSAS Instance and a specified SSAS Database

	Example:
		EXEC dbo.uspCreateLinkedServer
			@TenantDBName = 'EES_TestTenant_DW'

	Returns: NVARCHAR(300), The Job Name Created for Tenant Provisioning
	
	Change History
	==============================================================
	9/30/2019	FRANC583	Initial Version, CPI-796
**/
CREATE PROCEDURE [dbo].[uspCreateLinkedServer]
@TenantDBName NVARCHAR(200)
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @molap NVARCHAR(100) = (SELECT TOP 1 [SettingValue] FROM [mdm].[Settings] WHERE SettingName = 'SSASInstance');

	DECLARE @sql NVARCHAR(MAX) = '
	EXEC master.dbo.sp_addlinkedserver @server = ' + @TenantDBName + ', @srvproduct=N'''', @provider=N''MSOLAP'', @datasrc=N''' + @molap + N''', @catalog= ' + @TenantDBName + N'

	EXEC master.dbo.sp_addlinkedsrvlogin @rmtsrvname = ' + @TenantDBName + ',@useself=N''False'',@locallogin=NULL,@rmtuser=NULL,@rmtpassword=NULL

	EXEC master.dbo.sp_serveroption @server = ' + @TenantDBName + ', @optname=N''collation compatible'', @optvalue=N''false''

	EXEC master.dbo.sp_serveroption @server = ' + @TenantDBName + ', @optname=N''data access'', @optvalue=N''true''

	EXEC master.dbo.sp_serveroption @server = ' + @TenantDBName + ', @optname=N''rpc'', @optvalue=N''true''

	EXEC master.dbo.sp_serveroption @server = ' + @TenantDBName + ', @optname=N''rpc out'', @optvalue=N''true''

	EXEC master.dbo.sp_serveroption @server = ' + @TenantDBName + ', @optname=N''remote proc transaction promotion'', @optvalue=N''false''
	';

	IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = @TenantDBName)
		EXEC sp_executesql @sql;

END
