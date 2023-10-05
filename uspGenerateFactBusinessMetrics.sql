/**
	Summary:
		Generate the Business Metric Fact Table
	Example:
		EXEC dbo.uspGenerateFactBusinessMetrics

	Returns: None
	
	Change History
	==============================================================
	11/24/2020	FRANC583	CPI-3750 Business Metrics ETL
**/
CREATE PROCEDURE dbo.uspGenerateFactBusinessMetrics
AS
BEGIN
	DECLARE @SurveyKey INT;

	SELECT @SurveyKey = s.SurveyKey
	FROM dbo.dimSurvey s
	INNER JOIN staging.SurveyMetadata stg ON s.SurveyYear = stg.SurveyYear
			AND s.SurveyVersion = stg.SurveyVersion

	IF EXISTS (SELECT top 1 SurveyKey FROM dbo.dimSurvey WHERE SurveyKey = @SurveyKey AND HasBusinessMetrics = 1)
	BEGIN
		DECLARE @Unpivot NVARCHAR(MAX) = ''
		DECLARE @FlatTable NVARCHAR(100) = 'BusinessMetricsDataFlat'

		DECLARE @ColumnList NVARCHAR(MAX) = ''
	
	-- Insert the columns here
		DECLARE @TblColumnList TABLE
		(
			ID			INT IDENTITY(1,1),
			ColumnName	NVARCHAR(100)
		)

		INSERT INTO @TblColumnList
		SELECT 
			QUOTENAME(c.[name]) AS ColumnName
		FROM sys.columns c
		INNER JOIN sys.tables t ON c.object_id = t.object_id
		WHERE t.[name] = 'BusinessMetricsData'
			AND SCHEMA_NAME(t.schema_id) = 'staging'
			AND c.[name] <> 'Unit'

		SELECT 
			@ColumnList = @ColumnList + ColumnName + ','
		FROM @TblColumnList

		SET @ColumnList = LEFT(@ColumnList,LEN(@ColumnList) - 1)

		SET @Unpivot = '
		INSERT INTO dbo.FactBusinessMetrics
		(
			GroupKey,
			MetricValue,
			MetricKey,
			SurveyKey,
			MetricZScore,
			LastChangedDate,
			LastChangedBy
		)
		SELECT
			bmu.GroupKey,
			A.MetricValue,
			dim.MetricKey,
			' + CAST(@SurveyKey AS NVARCHAR(3)) + N' AS SurveyKey,
			IIF
			(
				STDEVP(1.0 * A.MetricValue) OVER(PARTITION BY dim.MetricKey) = 0,
				NULL,
				(1.0 * A.MetricValue - AVG(1.0 * A.MetricValue) OVER(PARTITION BY dim.MetricName))/STDEVP(1.0 * A.MetricValue) OVER(PARTITION BY dim.MetricName)
			) AS MetricZScore,
			GETDATE() AS LastChangedDate,
			SYSTEM_USER AS LastChangedBy
		FROM
		(
			SELECT 
				Unit,
				CAST([Value] AS FLOAT) as MetricValue,
				MetricName	 
			FROM staging.BusinessMetricsData
			UNPIVOT ([Value] for MetricName in (' + @ColumnList + ')) p
		)A
		INNER JOIN dbo.DimBusinessMetric dim ON dim.MetricName = A.MetricName
		INNER JOIN dbo.dimUnitsforBusinessMetricsPredictions bmu ON bmu.CodingLabel = A.Unit
		WHERE bmu.IsActive = 1
		';

		IF NOT EXISTS (SELECT top 1 SurveyKey FROM dbo.FactBusinessMetrics WHERE SurveyKey = @SurveyKey)
			AND EXISTS (SELECT top 1 SurveyKey FROM dbo.dimSurvey WHERE SurveyKey = @SurveyKey AND HasBusinessMetrics = 1)
		BEGIN
			EXEC sp_executesql @Unpivot;
		END;
	END;
END;
GO
