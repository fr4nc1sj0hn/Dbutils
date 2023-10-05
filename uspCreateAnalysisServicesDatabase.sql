/**
	Summary:
		Provision an Analysis Services Database for the Tenant including the components (Cube, Dims, etc.)

	Example:
		EXEC dbo.uspCreateAnalysisServicesDatabase
			@TenantDatabase = 'TenantDB'

	Returns: None
	
	Change History
	==============================================================
	6/07/2018	FRANC583	Initial Version

**/
CREATE PROCEDURE [dbo].[uspCreateAnalysisServicesDatabase]
	@TenantDatabase NVARCHAR(100)
AS
BEGIN
	DECLARE @XMLData XML;

	SELECT @XMLData = 
	(
		SELECT 
			CONVERT(XML, BulkColumn) 
		FROM OPENROWSET(BULK 'D:\DatamartFiles\CreateOLAPDatabase.xmla', SINGLE_BLOB) AS x
	)

	DECLARE @ConvertedData NVARCHAR(MAX) = CAST(@XMLData AS NVARCHAR(MAX))
	SET @ConvertedData = REPLACE(@ConvertedData,'EES_ModelDB_DW',@TenantDatabase);

	SELECT @ConvertedData

	EXEC (@ConvertedData) AT [SSAS];
END
