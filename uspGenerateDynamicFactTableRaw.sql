
/**
	Summary:
		Generates the Dynamic Fact Table for Response Scoring
	Example:
		EXEC dbo.uspGenerateDynamicFactTableRaw

	Returns: None
	
	Change History
	==============================================================
	10/28/2019	FRANC583	Initial Version to support Correlation
	10/06/2020	FRANC583	CPI-3606 Fixed MD5 hashing
**/
CREATE PROCEDURE [dbo].[uspGenerateDynamicFactTableRaw]
AS
BEGIN
	SET NOCOUNT ON;

	DROP TABLE IF EXISTS #temp;
	
	CREATE TABLE #temp
	(
		ID				INT IDENTITY(1,1),
		CQ				NVARCHAR(100),
		CQNumber		INT,
		CQName			NVARCHAR(100),
		dimTable		NVARCHAR(100),
		DimNumber		INT,
		IsCurrentlyUsed BIT --CPA-608
	);

	DROP TABLE IF EXISTS #CQs
	
	CREATE TABLE #CQS
	(
		CQ NVARCHAR(100),
		CQNumber INT
	);

	INSERT INTO  #CQs
	SELECT 
		CAST(col.[name] AS NVARCHAR(100)) AS CQ,
		CAST(replace(col.[name],'CQ','') AS int) as CQNumber
	FROM sys.columns col
	INNER JOIN sys.tables t ON col.object_id = t.object_id
	WHERE t.[name] = 'CodingResponse'
		AND col.[name] LIKE 'CQ%'
		AND SCHEMA_NAME(t.schema_id) = 'staging'

	-- The temp table will contain the metadata to create the fact table
	-- Will be created if the fact table is not yet existing
	INSERT INTO #temp
	(
		CQ,
		CQNumber,
		CQName,
		dimTable,
		DimNumber,
		IsCurrentlyUsed
	)
	SELECT
		a.CQ,
		a.CQNumber,
		q.CQName,
		q.dimTable,
		q.DimNumber,
		q.IsCurrentlyUsed --CPA-608
	FROM #CQs a
	INNER JOIN staging.CQList q ON a.CQNumber = q.CQNumber;

	DECLARE 
		@cols		NVARCHAR(MAX) = '',
		@colsdim	NVARCHAR(MAX) = '
			cod.RespondentID,';

	-- CPA-608: IF the dimension is not used, (IsCurrentlyUsed = 0), set the column in the select list to -1 (Dummy Dimension Key, No Response)
	SELECT @cols = @cols + 
	IIF
	(
		IsCurrentlyUsed = 1,N' 
			ISNULL(dim' + CAST(DimNumber AS NVARCHAR(4)) + '.GroupKey,-1) AS dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,',N'
			-1 AS dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,'
	)
	FROM staging.CQList;

	SET @cols = LEFT(@cols,LEN(@cols) - 1);


	SELECT @colsdim = @colsdim + ' 
			cod.dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,'
	FROM staging.CQList;

	SET @colsdim = LEFT(@colsdim,LEN(@colsdim) - 1);

	
	DECLARE @colsofFact NVARCHAR(MAX) = '
			RespondentID NVARCHAR(100),';

	SELECT @colsofFact = @colsofFact + ' 
			dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key BIGINT,'
	FROM #temp;

	
	/* 
		Here we are generating the Fact Table CREATE TABLE statement
		Why? Because the fact table will contain varying dimension key columns based on the coding groups of the tenant based on the staging.CQList Table

		Format is:

		IF OBJECT_ID('dbo.FactCodingResponse') IS NULL
			CREATE TABLE dbo.FactCodingResponse
			(
				RespondentID INT, 
				dimShiftKey BIGINT, 
				dimLocationKey BIGINT, 
				.
				.
				.
				OP NVARCHAR(10),
				OPNum NVARCHAR(10),
				ItemKey INT,
				SurveyKey INT,
				RespondentKey BIGINT
			)
		We have to rename the columns in future releases
	*/
	-- CPA-268: Added RespondentKey
	SET @colsofFact = @colsofFact + 
		'	
			OP NVARCHAR(10),
			OPNum NVARCHAR(10),
			ItemKey INT,
			SurveyKey INT,
			RespondentKey BIGINT,
			Response INT'


	DECLARE @Create nvarchar(MAX) = '
		CREATE TABLE dbo.FactCodingResponseRaw
		(' 
			+ @colsofFact + '
		) ON PSchSurveyKey(SurveyKey);'
	
	DECLARE @CreateCorrelTable nvarchar(MAX) = '
		CREATE TABLE dbo.FactCodingResponseZScores
		(' 
			+ @colsofFact + ',
			PID BIGINT,
			Category NVARCHAR(300),
			CategoryID INT,
			AvgResponse DECIMAL(18,5),
			StDevResponse DECIMAL(18,5),
			OPZScore DECIMAL(18,5),
			CategoryZScore DECIMAL(18,5)
		) ON PSchSurveyKey(SurveyKey);'
	
	IF OBJECT_ID('dbo.FactCodingResponseRaw') IS NULL
	BEGIN
		EXEC sp_executesql @Create;

		CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactCodingResponseRaw ON dbo.FactCodingResponseRaw;
		CREATE NONCLUSTERED INDEX IX_FactCodingResponseRaw_SurveyKey ON dbo.FactCodingResponseRaw(SurveyKey);
	END

	IF OBJECT_ID('dbo.FactCodingResponseZScores') IS NULL
	BEGIN
		EXEC sp_executesql @CreateCorrelTable;
		CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactCodingResponseZScores ON dbo.FactCodingResponseZScores;
	END
	
	-- Columns of the Fact Table will be used to generate the correct order in the SELECT Statement

	DECLARE @FactColumnList NVARCHAR(MAX) = N''

	SELECT @FactColumnList = @FactColumnList + N'
		' + col.name + N','
	FROM sys.columns col
	INNER JOIN sys.tables t ON col.object_id = t.object_id
	WHERE t.name = 'FactCodingResponseRaw'
		AND SCHEMA_NAME(t.schema_id) = 'dbo'

	SET @FactColumnList = LEFT(@FactColumnList,LEN(@FactColumnList) - 1);

	-- For the Final SELECT LIST
	DECLARE @cteColumnList NVARCHAR(MAX) = ''

	SELECT @cteColumnList = @cteColumnList + N'
		cte.' + col.name + ','
	FROM sys.columns col
	INNER JOIN sys.tables t ON col.object_id = t.object_id
	WHERE t.name = 'FactCodingResponseRaw'
		AND SCHEMA_NAME(t.schema_id) = 'dbo'

	SET @cteColumnList = LEFT(@cteColumnList,LEN(@cteColumnList) - 1);
	
	/*

	The following lines just construct this SQL statement dynamically

	INSERT INTO dbo.FactCodingResponse
	(
		RespondentID INT, 
		dimShiftKey BIGINT, 
		dimLocationKey BIGINT, 
		.
		.
		.
		OP,
		OPNum,
		ItemKey,
		SurveyKey
		RespondentKey
	)
	SELECT DISTINCT 
		cod.RespondentID, 
		cod.dimShiftKey, 
		cod.dimLocationKey, 
		.
		.
		.
		fct.OP,
		fct.OPNum,
		items.ItemKey,
		s.SurveyKey,
		r.RespondentKey
	FROM staging.FactOpinionResponse fct
	INNER JOIN 
	(
		
	SELECT DISTINCT 
		base.RespondentID, 
		ISNULL(dim1.GroupKey,-1) AS dimShiftKey, 
		ISNULL(dim2.GroupKey,-1) AS dimLocationKey, 
		.
		.
		.
	FROM staging.CodingResponse base 
		LEFT JOIN dbo.dimShiftKey dim1 ON base.CQ1 = dim1.CodingResponseID AND dim1.IsActive = 1 
		LEFT JOIN dbo.dimLocationKey dim2 ON base.CQ2 = dim2.CodingResponseID AND dim2.IsActive = 1 
		.
		.
		.
	)cod ON fct.RespondentID = cod.RespondentID
	LEFT JOIN dbo.dimOPItems items ON fct.OPNum = items.OP
		AND fct.ScaleMappingLabel = items.ScalePointLabel
	LEFT JOIN dbo.dimSurvey s ON s.SurveyYear = fct.SurveyYear
		AND s.SurveyVersion = fct.SurveyVersion
	LEFT JOIN dbo.DimRespondent r ON r.RespondentID = fct.RespondentID
	*/

	-- The -1 Dimension Key corresponds to a dummy dimension record

	DECLARE @activedim NVARCHAR(MAX) = '
	WHERE ';

	SELECT @activedim = @activedim + ' 
		dim' + CAST(CQNumber AS NVARCHAR(4)) + '.IsActive = 1 AND '
	FROM #Temp;

	-- remove extraneous 'AND'
	SET @activedim = LEFT(@activedim,LEN(@activedim) - 3);

	DECLARE @ClientID INT = CAST((SELECT ConfigValue FROM staging.Config WHERE ConfigName = 'ClientID') AS INT);
	DECLARE @clientIDN VARCHAR(20) = cast(@ClientID as  VARCHAR(20))
	

	DECLARE @sql NVARCHAR(MAX) = '
			SELECT DISTINCT RespondentIDHashed AS RespondentID,
				' + @cols + '
			FROM staging.CodingResponseHashed base';

	-- CPA-608: IF the dimension is not used, (IsCurrentlyUsed = 0), Do not include the Dimension in the JOIN Condition
	SELECT @sql = @sql + IIF
		(
			IsCurrentlyUsed = 1,N' 
			LEFT JOIN dbo.dim' +  DimTable + ' dim' + CAST(DimNumber AS NVARCHAR(4)) + ' ON base.' + CQ + ' = dim' + 
				CAST(DimNumber AS NVARCHAR(4)) + '.CodingResponseID AND dim' + CAST(DimNumber AS NVARCHAR(4)) + '.IsActive = 1',
			''
		)
	FROM #Temp;

	DECLARE @selectcolumns NVARCHAR(MAX) = ''

	SET @selectcolumns = REPLACE(@colsdim,'cod.','') + ',';

	-- CPA-268: Added RespondentKey
	SET @selectcolumns = @selectcolumns + '
		OP,
		OPNum,
		ItemKey,
		SurveyKey,
		RespondentKey,
		Response';

	DECLARE @factJOINKeys NVARCHAR(MAX) = N'';

	-- CPA-608: IF the dimension is not used, (IsCurrentlyUsed = 0), Do not include the Dimension Columns in the JOIN Keys
	SELECT @factJOINKeys = @factJOINKeys + N'
			fct.dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key = cte.dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key AND '
	FROM staging.CQList;


	DECLARE @factWhere NVARCHAR(MAX) = N'';

	-- CPA-608: IF the dimension is not used, (IsCurrentlyUsed = 0), Do not include the Dimension Columns in the WHERE Clause
	SELECT @factWhere = @factWhere + N'
			fct.dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key IS NULL AND'
	FROM staging.CQList;

	SET @factWhere = @factWhere + N'
			fct.SurveyKey IS NULL AND
			fct.ItemKey IS NULL AND
			fct.RespondentKey IS NULL
	';

	-- CPA-268: Added RespondentKey and DimRespondent
	SET @sql = '
	;WITH cte AS
	(
		SELECT DISTINCT ' +
			@colsdim + ',
			fct.OP,
			fct.OPNum,
			items.CategoryItemKey AS ItemKey,
			s.SurveyKey,
			r.RespondentKey,
			fct.CorrelationValue AS Response
		FROM staging.FactOpinionResponse fct
		INNER JOIN 
		(
			' + @sql + '
		)cod ON fct.RespondentID = cod.RespondentID
		LEFT JOIN dbo.DimCategoryItem items ON fct.PID = items.PID
		LEFT JOIN dbo.dimSurvey s ON s.SurveyYear = fct.SurveyYear
			AND s.SurveyVersion = fct.SurveyVersion
		LEFT JOIN dbo.DimRespondent r ON r.RespondentID = fct.RespondentID
		WHERE items.IsActive = 1
	)
	INSERT INTO dbo.FactCodingResponseRaw
	(' + 
		@FactColumnList + 
	')
	SELECT
	' + @cteColumnList + '
	FROM cte';

	/*
	LEFT JOIN dbo.FactCodingResponseRaw fct ON ' + @factJOINKeys + '
			fct.SurveyKey = cte.SurveyKey AND 
			fct.ItemKey = cte.ItemKey AND
			fct.RespondentKey = cte.RespondentKey
	WHERE ' + @factWhere ;

	PRINT @sql;
	*/
	EXEC sp_executesql @sql;

	-- CPA-608: Recently Added Dimensions have NULL as the DimensionKeys in the Fact Table, set them to -1 instead so that errors will not be encountered during Cube Processing
	DECLARE @UpdateDummyKeys NVARCHAR(MAX) = '';

	DROP INDEX [CCI_FactCodingResponseRaw] ON [dbo].[FactCodingResponseRaw];

	SELECT @UpdateDummyKeys = @UpdateDummyKeys + '
	UPDATE dbo.FactCodingResponseRaw
	SET dim' + dimTable + 'Key = -1
	WHERE dim' + dimTable + 'Key IS NULL;'
	FROM #Temp WHERE IsCurrentlyUsed = 1;

	EXEC sp_executesql @UpdateDummyKeys;

	CREATE CLUSTERED COLUMNSTORE INDEX [CCI_FactCodingResponseRaw] ON [dbo].[FactCodingResponseRaw];
	

	-- Correlation ZScores
	EXEC corr.uspGenerateRespondentZScores;
END;
GO