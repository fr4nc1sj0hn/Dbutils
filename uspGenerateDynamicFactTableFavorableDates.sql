/**
	Summary:
		Generates the Dynamic Fact Table for Favorable Scoring with Dynamic Date Dimension
	Example:
		EXEC dbo.uspGenerateDynamicFactTableFavorable

	Returns: None

	Change History
	==============================================================
	10/29/2019	FRANC583	Initial Version
	12/03/2019	FRANC583	CPI-1072
	10/06/2020	FRANC583	CPI-3606 Fixed MD5 hashing
	01/28/2021	FRANC583	Combine Fact Tables into one
	11/02/2021	FRANC583	http://jira.ehr.com/browse/CPI-6659
**/
CREATE PROCEDURE [dbo].[uspGenerateDynamicFactTableFavorableDates]
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
	/**
	CPI-827: if Date Information is loaded in staging.CQList BUT staging.RespondentDateInformation is not loaded, then it means the dates are loaded in the past but now is not supplied
	Therefore we assign dummy keys
	*/

	IF EXISTS (SELECT 1 FROM staging.CQList WHERE CQNumber >= 1000) AND EXISTS (SELECT 1 FROM sys.tables WHERE [name] = 'RespondentDateInformation')
	BEGIN
		SELECT @cols = @cols + IIF
		(
			IsCurrentlyUsed = 1,N'
				ISNULL(' + 
				IIF(
					CQNumber<1000,
					N'dim' + CAST(DimNumber AS NVARCHAR(4)) + N'.GroupKey,-1) AS dim',
					N'resp.' + dimTable + N'Key,99991231) AS dim'
				) + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,',
			 IIF(
				CQNumber<1000,
				N' -1 AS dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,',
				N' 99991231 AS dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,'
			)
		)
		FROM staging.CQList;
	END;
	-- This means date info is loaded in the past
	IF EXISTS (SELECT 1 FROM staging.CQList WHERE CQNumber >= 1000) AND NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = 'RespondentDateInformation')
	BEGIN
		SELECT @cols = @cols + IIF
		(
			IsCurrentlyUsed = 1,N'
			ISNULL(' + 
				IIF(
					CQNumber<1000,
					'dim' + CAST(DimNumber AS NVARCHAR(4)) + N'.GroupKey,-1) AS dim',
					N'NULL,99991231) AS dim'
				) + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,',
			 IIF(
				CQNumber<1000,
				N' -1 AS dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,',
				N' 99991231 AS dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,'
			)
		)
		FROM staging.CQList;
	END;

	SET @cols = LEFT(@cols,LEN(@cols) - 1);


	SELECT @colsdim = @colsdim + N' 
			ISNULL(cod.dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,-1) AS dim' + CAST(dimTable AS NVARCHAR(MAX)) + 'Key,'
	FROM staging.CQList;

	SET @colsdim = LEFT(@colsdim,LEN(@colsdim) - 1);


	DECLARE @colsofFact NVARCHAR(MAX) = N'
			RespondentID NVARCHAR(100),';

	SELECT @colsofFact = @colsofFact + N' 
			dim' + CAST(dimTable AS NVARCHAR(MAX)) + N'Key BIGINT,'
	FROM  staging.CQList;



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
				RespondentKey BIGINT,
				FavorableScore INT,
				UnfavorableScore INT,
				NeutralScore INT
			)
		We have to rename the columns in future releases
	*/
	-- CPA-268: Added RespondentKey
	SET @colsofFact = @colsofFact + 
		N'	
			OP NVARCHAR(10),
			OPNum NVARCHAR(10),
			ItemKey INT,
			SurveyKey INT,
			RespondentKey BIGINT,
			FavorableScore INT,
			UnfavorableScore INT,
			NeutralScore INT,
			Response INT,
			CorrelationValue INT,
			PID BIGINT,
			CategoryItemKey INT,
			Category NVARCHAR(300),
			CategoryID INT,
			AvgResponse DECIMAL(18,5),
			StDevResponse DECIMAL(18,5),
			OPZScore DECIMAL(18,5),
			CategoryZScore DECIMAL(18,5)'


	DECLARE @Create nvarchar(MAX) = '
		CREATE TABLE dbo.FactCodingResponse
		(' 
			+ @colsofFact + '
		) ON PSchSurveyKey(SurveyKey);'


	IF OBJECT_ID('dbo.FactCodingResponse') IS NULL
	BEGIN
		EXEC sp_executesql @Create;

		CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactCodingResponse ON dbo.FactCodingResponse;
		CREATE NONCLUSTERED INDEX IX_FactCodingResponse_SurveyKey ON dbo.FactCodingResponse(SurveyKey);
	END


	-- Columns of the Fact Table will be used to generate the correct order in the SELECT Statement

	DECLARE @FactColumnList NVARCHAR(MAX) = N''

	SELECT @FactColumnList = @FactColumnList + N'
		' + col.name + N','
	FROM sys.columns col
	INNER JOIN sys.tables t ON col.object_id = t.object_id
	WHERE t.name = 'FactCodingResponse'
		AND SCHEMA_NAME(t.schema_id) = 'dbo'
		AND col.name  <> 'CategoryZScore'

	AND col.name  <> 'CategoryZScore'

	SET @FactColumnList = LEFT(@FactColumnList,LEN(@FactColumnList) - 1);
	SET @FactColumnList =  @FactColumnList + N',
		CategoryZScore
	'

	-- For the Final SELECT LIST
	DECLARE @cteColumnList NVARCHAR(MAX) = ''

	SELECT @cteColumnList = @cteColumnList + N'
		cte.' + col.name + ','
	FROM sys.columns col
	INNER JOIN sys.tables t ON col.object_id = t.object_id
	WHERE t.name = 'FactCodingResponse'
		AND SCHEMA_NAME(t.schema_id) = 'dbo'
		AND col.name  <> 'CategoryZScore'

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
		RespondentKey,
		FavorableScore,
		UnfavorableScore,
		NeutralScore
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
		r.RespondentKey,
		fct.FavorableScore,
		fct.UnfavorableScore,
		fct.NeutralScore
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


	DECLARE @activedim NVARCHAR(MAX) = '
	WHERE ';

	SELECT @activedim = @activedim + ' 
		dim' + CAST(CQNumber AS NVARCHAR(4)) + '.IsActive = 1 AND '
	FROM #Temp;

	-- remove extraneous 'AND'
	SET @activedim = LEFT(@activedim,LEN(@activedim) - 3);



	DECLARE @ClientID INT = CAST((SELECT ConfigValue FROM staging.Config WHERE ConfigName = 'ClientID') AS INT);
	DECLARE @clientIDN VARCHAR(20) = cast(@ClientID as  VARCHAR(20))


	DECLARE @sql NVARCHAR(MAX) = N''
	IF EXISTS (SELECT 1 FROM staging.CQList WHERE CQNumber >= 1000) AND EXISTS (SELECT 1 FROM sys.tables WHERE [name] = 'RespondentDateInformation')
	BEGIN

		-- If the Respondent ID is an invalid MD5 Hash, we hash it
		SET @sql = N'
		SELECT DISTINCT RespondentIDHashed AS RespondentID,
				' + @cols + '
				INTO staging.CodingWithGroupKeys
			FROM staging.CodingResponseHashed base
			LEFT JOIN staging.RespondentDateInformationKeys resp ON base.RespondentID = resp.RespondentID';
	END;

	IF EXISTS (SELECT 1 FROM staging.CQList WHERE CQNumber >= 1000) AND NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = 'RespondentDateInformation')
	BEGIN
		SET @sql = N'
		SELECT DISTINCT RespondentIDHashed AS RespondentID,
			' + @cols + '
			INTO staging.CodingWithGroupKeys
		FROM staging.CodingResponseHashed base';
	END;


	-- CPA-608: IF the dimension is not used, (IsCurrentlyUsed = 0), Do not include the Dimension in the JOIN Condition
	SELECT @sql = @sql + IIF
		(
			IsCurrentlyUsed = 1,' 
			LEFT JOIN dbo.dim' +  DimTable + ' dim' + CAST(DimNumber AS NVARCHAR(4)) + ' ON base.' + IIF(CQNumber<1000,N'CQ' + CAST(CQNumber AS NVARCHAR(4)),'RespondentID') + ' = dim' + 
				CAST(DimNumber AS NVARCHAR(4)) + IIF(CQNumber<1000,'.CodingResponseID','.RespondentID') + IIF(CQNumber<1000,N' AND dim' + CAST(DimNumber AS NVARCHAR(4)) + '.IsActive = 1',''),
			''
		)
	FROM staging.CQList WHERE CQNumber < 1000;

	DROP TABLE IF EXISTS staging.CodingWithGroupKeys;

	SELECT @sql
	EXEC sp_executesql @sql;

	CREATE CLUSTERED INDEX CI_CodingWithGroupKeys ON staging.CodingWithGroupKeys(RespondentID);



	DECLARE @selectcolumns NVARCHAR(MAX) = ''

	SET @selectcolumns = REPLACE(@colsdim,'cod.','') + ',';

	-- CPA-268: Added RespondentKey
	SET @selectcolumns = @selectcolumns + '
		OP,
		OPNum,
		ItemKey,
		SurveyKey,
		RespondentKey,
		FavorableScore,
		UnfavorableScore,
		NeutralScore,
		Response,
		CorrelationValue,
		PID,
		CategoryItemKey,
		Category,
		CategoryID,
		AvgResponse,
		StDevResponse,
		OPZScore,
		CategoryZScore';

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
	DECLARE @cte NVARCHAR(MAX) = N'
	;WITH cte AS
	(
		SELECT DISTINCT ' +
			@colsdim + ',
			fct.OP,
			fct.OPNum,
			fct.ItemKey,
			s.SurveyKey,
			r.RespondentKey,
			fct.FavorableScore,
			fct.UnfavorableScore,
			fct.NeutralScore,
			fct.Response,
			fct.CorrelationValue,
			fct.PID,
			catitem.CategoryItemKey,
			fct.Category,
			cat.CategoryID,
			AVG(1.0 * fct.CorrelationValue) OVER(PARTITION BY fct.PID,s.SurveyKey) AS AvgResponse,
			STDEVP(1.0 * fct.CorrelationValue) OVER(PARTITION BY fct.PID,s.SurveyKey) AS StDevResponse,
			IIF
			(
				STDEVP(1.0 * fct.CorrelationValue) OVER(PARTITION BY catitem.PID,s.SurveyKey) = 0,
				NULL,
				(1.0 * fct.CorrelationValue - AVG(1.0 * CorrelationValue) OVER(PARTITION BY fct.PID,s.SurveyKey))/STDEVP(1.0 * fct.CorrelationValue) OVER(PARTITION BY fct.PID,s.SurveyKey)
			) AS OPZScore
		FROM staging.FactOpinionResponse fct
		INNER JOIN staging.CodingWithGroupKeys cod ON fct.RespondentID = cod.RespondentID
		LEFT JOIN dbo.dimSurvey s ON s.SurveyYear = fct.SurveyYear
			AND s.SurveyVersion = fct.SurveyVersion
		LEFT JOIN dbo.DimRespondent r ON r.RespondentID = fct.RespondentID
		INNER JOIN dbo.DimCategoryItem catitem ON catitem.PID = fct.PID
		INNER JOIN dbo.Category cat ON catitem.Category = cat.Category
	)
	SELECT 
	' + @cteColumnList + '
	INTO staging.FactWithZScores
	FROM cte;
	';

	DROP TABLE IF EXISTS staging.FactWithZScores;

	EXEC sp_executesql @cte;

	DROP TABLE IF EXISTS staging.FactWithCatZScores
	SELECT
		*,
		AVG(OPZScore) OVER(PARTITION BY Category,RespondentID,SurveyKey) AS CategoryZScore
	INTO staging.FactWithCatZScores
	FROM staging.FactWithZScores 

	--SELECT TOP 10 * FROM staging.FactWithCatZScores;

	DROP TABLE IF EXISTS dbo.FactCodingResponse2;

	DECLARE @createFact2 NVARCHAR(MAX) = N'
	CREATE TABLE dbo.FactCodingResponse2
	(
		';

	SELECT @createFact2 = @createFact2 + [name] +
		CASE [name]
			WHEN 'RespondentID' THEN N' NVARCHAR(100)'
			WHEN 'OP' THEN N' NVARCHAR(10)' 
			WHEN 'OPNum' THEN N' NVARCHAR(10)'
			WHEN 'ItemKey' THEN N' INT'
			WHEN 'SurveyKey' THEN N' INT'
			WHEN 'RespondentKey' THEN N' BIGINT'
			WHEN 'FavorableScore' THEN N' INT'


			WHEN 'UnfavorableScore' THEN N' INT'
			WHEN 'NeutralScore' THEN N' INT'
			WHEN 'Response' THEN N' INT'
			WHEN 'CorrelationValue' THEN N' INT'
			WHEN 'PID' THEN N' BIGINT'
			WHEN 'CategoryItemKey' THEN N' INT'

			WHEN 'Category' THEN N' NVARCHAR(300)'
			WHEN 'CategoryID' THEN N' INT'

			WHEN 'AvgResponse' THEN N' DECIMAL(18,5)'

			WHEN 'StDevResponse' THEN N' DECIMAL(18,5)'
			WHEN 'OPZScore' THEN N' DECIMAL(18,5)'
			WHEN 'CategoryZScore' THEN N' DECIMAL(18,5)'

			ELSE ' BIGINT'


		END  + N',
		'
	--c.[name],t.[name]
	FROM sys.columns
	WHERE OBJECT_NAME(object_id) = 'FactCodingResponse'

	ORDER BY column_id;


	SET  @createFact2 = LEFT(@createFact2,LEN(@createFact2) - 5);
	SET  @createFact2 = @createFact2 + N'
	) ON PSchSurveyKey(SurveyKey);';


	EXEC sp_executesql @createFact2

	DECLARE @insertToFact2 NVARCHAR(MAX) = N'
	INSERT INTO dbo.FactCodingResponse2 WITH (TABLOCK)
	(
		' + @FactColumnList + N'
	)
	SELECT * FROM staging.FactWithCatZScores;'

	EXEC sp_executesql @insertToFact2

	CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactCodingResponse2 ON dbo.FactCodingResponse2;
	CREATE NONCLUSTERED INDEX IX_FactCodingResponse2_SurveyKey ON dbo.FactCodingResponse2(SurveyKey); --39s

	DECLARE @SurveyKey INT = (SELECT TOP 1 SurveyKey FROM dbo.FactCodingResponse2);

	DECLARE @switch NVARCHAR(MAX) = N'
	ALTER TABLE dbo.FactCodingResponse2 SWITCH PARTITION ' + CAST(@SurveyKey AS NVARCHAR(2)) + N' TO dbo.FactCodingResponse PARTITION ' + CAST(@SurveyKey AS NVARCHAR(2));

	EXEC sp_executesql @switch;

END;
GO
