/**
	Summary:
		Delete data from Fact Table
	Example:
		EXEC dbo.uspDeleteFactData
			@SurveyKey = 1
	

	SELECT * FROM dbo.DImSurvey
	Returns: None
	
	Change History
	==============================================================
	8/22/2018	FRANC583	Initial Version		CPA-263
	11/24/2020	FRANC583	CPI-3750 Business Metrics ETL
**/
CREATE PROCEDURE [dbo].[uspDeleteFactData] 
	@SurveyKey INT
AS
BEGIN
	DECLARE @DBName NVARCHAR(100) = DB_NAME(DB_ID());

	IF OBJECT_ID(N'dbo.FactCodingResponse') IS NOT NULL
		TRUNCATE TABLE dbo.FactCodingResponse
		WITH (PARTITIONS (@SurveyKey));
	
	IF OBJECT_ID(N'dbo.FactCodingResponseRaw') IS NOT NULL
		TRUNCATE TABLE dbo.FactCodingResponseRaw
		WITH (PARTITIONS (@SurveyKey));
	

	IF OBJECT_ID(N'dbo.FactCodingResponseZScores') IS NOT NULL
		TRUNCATE TABLE dbo.FactCodingResponseZScores
		WITH (PARTITIONS (@SurveyKey));
	

	IF OBJECT_ID(N'dbo.FactOpinionCodingResponse') IS NOT NULL
		TRUNCATE TABLE dbo.FactOpinionCodingResponse
		WITH (PARTITIONS (@SurveyKey));

	IF OBJECT_ID(N'dbo.FactComments') IS NOT NULL
	BEGIN
		UPDATE dbo.FactComments
		SET IsDeleted = 1
		WHERE SurveyKey = @SurveyKey;
	END;

	DECLARE @sql NVARCHAR(MAX) = N'';

	IF EXISTS (SELECT 1 FROM dbo.dimSurvey WHERE HasBusinessMetrics = 1 AND SurveyKey = @SurveyKey)
	BEGIN
		DELETE FROM dbo.FactBusinessMetrics WHERE SurveyKey = @SurveyKey;


		DELETE FROM dbo.CorrelationBMQuestionsCacheResult WHERE SurveyKey = @SurveyKey;
		DELETE FROM dbo.CorrelationBMCategoriesCacheResult WHERE SurveyKey = @SurveyKey;
		DELETE FROM dbo.BMCategoryDrillTableCacheResult WHERE SurveyKey = @SurveyKey;
		DELETE FROM dbo.BMCategoryDrillChartCacheResult WHERE SurveyKey = @SurveyKey;


		DELETE FROM dbo.PreCalculatedValuesBMCategoryUnitCatNSize WHERE SurveyKey = @SurveyKey;
		DELETE FROM dbo.PreCalculatedValuesBMCategoryUnitCatZScore WHERE SurveyKey = @SurveyKey;
		DELETE FROM dbo.PreCalculatedValuesBMCategoryUnitMetricsZScores WHERE SurveyKey = @SurveyKey;
		DELETE FROM dbo.PreCalculatedValuesBMQuestionsUnitCatNSize WHERE SurveyKey = @SurveyKey;
		DELETE FROM dbo.PreCalculatedValuesBMQuestionsUnitCatZScore WHERE SurveyKey = @SurveyKey;
		DELETE FROM dbo.PreCalculatedValuesModalCatChart WHERE SurveyKey = @SurveyKey;
		DELETE FROM dbo.PreCalculatedValuesModalQuestions WHERE SurveyKey = @SurveyKey;

		SET @sql = N'
		<Delete xmlns="http://schemas.microsoft.com/analysisservices/2003/engine">
			<Object>
				<DatabaseID>' + @DBName + N'</DatabaseID>
				<CubeID>BusinessMetrics</CubeID>
				<MeasureGroupID>Fact Business Metrics</MeasureGroupID>
				<PartitionID>SurveyKey ' + CAST(@SurveyKey AS NVARCHAR(2)) + N'</PartitionID>
			</Object>
		</Delete>'

		EXEC (@sql) AT [SSAS];
	END;

	DELETE FROM dbo.dimSurvey WHERE SurveyKey = @SurveyKey;
	
	-- Delete Cache Entries
	-- dbo.CorrelationCatToCatCacheResult
	DELETE FROM dbo.CorrelationCatToCatCacheResult WHERE SurveyKey1 = @SurveyKey;
	DELETE FROM dbo.CorrelationCatToCatCacheResult WHERE SurveyKey2 = @SurveyKey;

	-- dbo.CorrelationCatToOPCacheResult
	DELETE FROM dbo.CorrelationCatToOPCacheResult WHERE SurveyKey1 = @SurveyKey;
	DELETE FROM dbo.CorrelationCatToOPCacheResult WHERE SurveyKey2 = @SurveyKey;

	-- dbo.CorrelationCatToOPCacheResult
	DELETE FROM dbo.CorrelationOPToCatCacheResult WHERE SurveyKey1 = @SurveyKey;
	DELETE FROM dbo.CorrelationOPToCatCacheResult WHERE SurveyKey2 = @SurveyKey;

	
	-- dbo.CorrelationCatToOPCacheResult
	DELETE FROM dbo.CorrelationOPToOPCacheResult WHERE SurveyKey1 = @SurveyKey;
	DELETE FROM dbo.CorrelationOPToOPCacheResult WHERE SurveyKey2 = @SurveyKey;

	-- dbo.CorrelationCatToOPCacheResult
	DELETE FROM dbo.CorrelationTurnoverCacheResult WHERE SurveyKey = @SurveyKey;
	DELETE FROM dbo.CorrelationTurnoverCacheResult WHERE SurveyKey = @SurveyKey;


	-- Delete Cube Partition
	SET @sql = N'
	<Delete xmlns="http://schemas.microsoft.com/analysisservices/2003/engine">
    <Object>
        <DatabaseID>' + @DBName + N'</DatabaseID>
        <CubeID>OpinionInsightsDynamicDim</CubeID>
        <MeasureGroupID>Fact Coding Response</MeasureGroupID>
        <PartitionID>SurveyKey ' + CAST(@SurveyKey AS NVARCHAR(2)) + N'</PartitionID>
    </Object>
	</Delete>';
	
	DECLARE @ProcessUpdate NVARCHAR(MAX) = N'
	<Batch xmlns="http://schemas.microsoft.com/analysisservices/2003/engine">
	  <Parallel>
		<Process xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:ddl2="http://schemas.microsoft.com/analysisservices/2003/engine/2" xmlns:ddl2_2="http://schemas.microsoft.com/analysisservices/2003/engine/2/2" xmlns:ddl100_100="http://schemas.microsoft.com/analysisservices/2008/engine/100/100" xmlns:ddl200="http://schemas.microsoft.com/analysisservices/2010/engine/200" xmlns:ddl200_200="http://schemas.microsoft.com/analysisservices/2010/engine/200/200" xmlns:ddl300="http://schemas.microsoft.com/analysisservices/2011/engine/300" xmlns:ddl300_300="http://schemas.microsoft.com/analysisservices/2011/engine/300/300" xmlns:ddl400="http://schemas.microsoft.com/analysisservices/2012/engine/400" xmlns:ddl400_400="http://schemas.microsoft.com/analysisservices/2012/engine/400/400" xmlns:ddl500="http://schemas.microsoft.com/analysisservices/2013/engine/500" xmlns:ddl500_500="http://schemas.microsoft.com/analysisservices/2013/engine/500/500">
		  <Object>
			<DatabaseID>' + @DBName + N'</DatabaseID>
			<DimensionID>Dim Survey</DimensionID>
		  </Object>
		  <Type>ProcessUpdate</Type>
		  <WriteBackTableCreation>UseExisting</WriteBackTableCreation>
		</Process>
	  </Parallel>
	</Batch>
	';

	BEGIN TRY
		EXEC (@sql) AT [SSAS]
		EXEC (@ProcessUpdate) AT [SSAS]
	END TRY

	BEGIN CATCH
		PRINT ERROR_MESSAGE();
	END CATCH


	
	
	EXEC util.uspShrinkDatabase;

	IF NOT EXISTS (SELECT 1 FROM dbo.DimSurvey WHERE SurveyKey <> -1) 
	BEGIN
		EXEC [dbo].[uspClearDimsAndFacts];
	END
END;