/**
	Summary:
		Get Data for Main Turnover Dashboard 
	Example:
		EXEC [corr].[uspTurnOverCorrelation]
			@Population	 = 'All',
			@SurveyKey = '2',
			@Category = N'All'

	Returns: TABLE
	
	Change History
	==============================================================
	08/06/2020		FRANC583	Initial Creation
	08/10/2020		FRANC583	Store Results to a Table
	02/19/2021		FRANC583	Single Fact Table
**/
CREATE PROCEDURE [corr].[uspTurnOverCorrelation]
@Population	NVARCHAR(1000)	= 'All',
@SurveyKey NVARCHAR(10),
@Category NVARCHAR(1000)	= N'All', -- '1,2,3',
@Session NVARCHAR(100)		= N''
AS
BEGIN
	SET NOCOUNT ON;
	
	DROP TABLE IF EXISTS #results;
	CREATE TABLE #results
	(
		PID								BIGINT,
		ItemText						NVARCHAR(500),
		Category						NVARCHAR(500),
		NSizeCutOff						FLOAT,
		FavorableResponse				FLOAT,
		UnfavorableResponse				FLOAT,
		NeutralResponse					FLOAT,
		FavorablePercentage				DECIMAL(18,5),
		NeutralPercentage				DECIMAL(18,5),
		UnfavorablePercentage			DECIMAL(18,5),
		UnfavorableTurnOverRatio		DECIMAL(18,5),
		FavorableTurnOverRatio			DECIMAL(18,5),
		UnfavorableTurnOverRatioFiller	DECIMAL(18,5),
		FavorableTurnOverRatioFiller	DECIMAL(18,5),
		CorrelationStrength				DECIMAL(18,5),
		CorrelationStrengthState		DECIMAL(18,5),
		CorrelationRespondentCount		BIGINT,
		IsStatisticallySignificant		BIT
	);

	IF @SurveyKey = N'All'
		SET @SurveyKey = (SELECT TOP 1 CAST(SurveyKey AS NVARCHAR(3)) FROM dbo.DimSurvey WHERE HasTurnoverData = 1);
	
	IF EXISTS (SELECT 1 FROM dbo.dimSurvey WHERE SurveyKey = CAST(@SurveyKey AS INT) AND HasTurnoverData = 1)
	BEGIN
		-- if There is no leaver data
		DECLARE @leaversSQL NVARCHAR(1000) = N'
		SELECT COUNT(1) as Leavers
		FROM [dbo].[FactCodingResponse] fct
		INNER JOIN dbo.DimTurnover dt ON fct.DimTurnoverKey = dt.GroupKey
			AND SurveyKey = ' + @SurveyKey + N'
			AND dt.CodingResponseID = 1'

		DECLARE	@leavers TABLE
		(
			LeaversCount BIGINT
		);

		INSERT INTO @leavers EXEC sp_executesql @leaversSQL;

		IF (SELECT LeaversCount FROM @leavers) = 0
		BEGIN
			SELECT * FROM #results;

			RETURN;
		END;
	END;

	-- For the cache results.
	DECLARE @groupsorted NVARCHAR(MAX) = N''
	SELECT @groupsorted = @groupsorted + [value] + N',' FROM 
	(
		SELECT [value] FROM  string_split(@Population,N',')val
	)A
	ORDER BY [value];

	SET @groupsorted = LEFT(@groupsorted,LEN(@groupsorted) - 1);
	
	DECLARE @GroupFilterID BIGINT = (SELECT dbo.svfGetGroupFilterID(@groupsorted));

	-- All Categories
	IF EXISTS (SELECT 1 FROM dbo.CorrelationTurnoverCacheResult WHERE SurveyKey = CAST(@SurveyKey AS INT) AND CorrelationGroupFilterID = @GroupFilterID AND CategoryParam = @Category)
	BEGIN
		SELECT
			PID								= tov.PID
			,ItemText						= ci.ItemText
			,Category						= c.Category
			,NSizeCutOff					= tov.NSizeCutOff
			,FavorableResponse				= tov.FavorableResponse
			,UnfavorableResponse			= tov.UnfavorableResponse
			,NeutralResponse				= tov.NeutralResponse
			,FavorablePercentage			= tov.FavorablePercentage
			,NeutralPercentage				= tov.NeutralPercentage
			,UnfavorablePercentage			= tov.UnfavorablePercentage
			,UnfavorableTurnOverRatio		= tov.UnfavorableTurnOverRatio
			,FavorableTurnOverRatio			= tov.FavorableTurnOverRatio
			,UnfavorableTurnOverRatioFiller = tov.UnfavorableTurnOverRatioFiller
			,FavorableTurnOverRatioFiller	= tov.FavorableTurnOverRatioFiller
			,CorrelationStrength			= tov.CorrelationStrength
			,CorrelationStrengthState		= tov.CorrelationStrengthState
			,CorrelationRespondentCount		= tov.CorrelationRespondentCount
			,IsStatisticallySignificant		= tov.IsStatisticallySignificant
			,CriticalValue					= tov.CriticalValue
		FROM dbo.CorrelationTurnoverCacheResult tov
		INNER JOIN dbo.DimCategoryItem ci ON tov.PID = ci.PID
		INNER JOIN dbo.Category c ON c.CategoryID = tov.CategoryID
		WHERE tov.CorrelationGroupFilterID = @GroupFilterID
			AND tov.SurveyKey = CAST(@SurveyKey AS INT)
			AND tov.FavorablePercentage IS NOT NULL
			AND (tov.FavorableTurnOverRatio IS NOT NULL OR tov.UnfavorableTurnOverRatio IS NOT NULL)
			AND CategoryParam = @Category
		ORDER BY tov.CorrelationStrength ASC;

		RETURN;
	END;

	DECLARE @globaltable NVARCHAR(100) = N'##' + REPLACE(CAST(NEWID() AS NVARCHAR(100)),'-','');
	DECLARE @survey1Table NVARCHAR(100) = @globaltable + N'_Survey1';

	IF OBJECT_ID(N'dbo.DimTurnOver') IS NULL OR @SurveyKey = ''
	BEGIN
		SELECT * FROM #results;
		RETURN;
	END;
	ELSE
	BEGIN
		DECLARE @checkSQL NVARCHAR(MAX) = N'
		SELECT COUNT(*) AS CountRows FROM dbo.FactCodingResponse WHERE SurveyKey = ' + @SurveyKey + N' AND DimTurnOverKey <> -1
		';

		DECLARE @count TABLE
		(
			CountRows BIGINT
		);

		INSERT INTO @count EXEC sp_executesql @checkSQL;

		IF (SELECT CountRows FROM @count) = 0
		BEGIN
			SELECT * FROM #results;
			RETURN
		END;

		
	END;
	
	IF (@Population = '') OR (@Category = '')
    BEGIN
		SELECT * FROM #results;
		RETURN;
    END
    
	DECLARE @whereCorrelation NVARCHAR(MAX) = N'';
	
	DROP TABLE IF EXISTS #childkeys
	-- Generate the GroupKeys recursively
    CREATE TABLE #childkeys
    (
        GroupKey 		BIGINT,
		ParentCQName	NVARCHAR(1000)
    );
	CREATE CLUSTERED INDEX CI_#childkeys ON #childkeys(GroupKey);
	CREATE NONCLUSTERED INDEX NCI_#childkeys ON #childkeys(ParentCQName) INCLUDE(GroupKey);
        
	IF @Population = 'All'
    BEGIN
		SET @whereCorrelation = N'WHERE 1 = 1 ';
    END
    ELSE
    BEGIN
		DECLARE @criteriaRoot NVARCHAR(MAX) = N'';

		DECLARE @GroupKeysRoot TABLE
		(
			ID			INT IDENTITY(1,1),
			GroupKey	BIGINT
		);
		DECLARE @GroupKeysNotRoot TABLE
		(
			ID			INT IDENTITY(1,1),
			GroupKey	BIGINT
		);
		
		INSERT INTO @GroupKeysRoot
		SELECT [value] AS GroupKey 
		FROM string_split(@Population,',') g
		INNER JOIN dbo.dimGroup dg ON g.value = dg.GroupKey 
		WHERE ParentGroupKey IS NULL;
		
		SELECT 
			@criteriaRoot	= @criteriaRoot + N'
								Dim' + dbo.svfRemoveNonAlphaCharacters(ParentCQName) + N'Key IS NOT NULL AND'
		FROM @GroupKeysRoot g
		INNER JOIN dbo.dimGroup dg ON g.GroupKey = dg.GroupKey

		IF @criteriaRoot <> N''
			SET @criteriaRoot = N' AND ' + LEFT(@criteriaRoot,LEN(@criteriaRoot) - 3);

		INSERT INTO @GroupKeysNotRoot
		SELECT [value] AS GroupKey 
		FROM string_split(@Population,',') g
		INNER JOIN dbo.dimGroup dg ON g.value = dg.GroupKey 
		WHERE ParentGroupKey IS NOT NULL;
		
		DECLARE @insertKeys NVARCHAR(MAX) = N'';

		SELECT @insertKeys = @insertKeys + N'
			INSERT INTO #childkeys EXEC dbo.uspGenerateGroups @Group = ' + CAST(GroupKey AS NVARCHAR(10)) + N';'
		FROM @GroupKeysNotRoot;

		EXEC sp_executesql @insertKeys;

		IF (SELECT COUNT(*) FROM #childkeys) = 0 AND (@criteriaRoot = N'')
		BEGIN
			SELECT * FROM #results;
			RETURN;
		END;

		DECLARE @Groups NVARCHAR(MAX) = N''

		SELECT @Groups = @Groups + N'
		INNER JOIN (SELECT GroupKey FROM #childkeys WHERE ParentCQName = ''' + ParentCQName + N''') ' + dbo.svfRemoveNonAlphaCharacters(ParentCQName) + N' ON fct.Dim' + dbo.svfRemoveNonAlphaCharacters(ParentCQName) + N'Key = ' + dbo.svfRemoveNonAlphaCharacters(ParentCQName) + N'.GroupKey'
		FROM 
		(
			SELECT DISTINCT ParentCQName FROM #childkeys
		)a;

		SET @whereCorrelation = @Groups + N'
		WHERE 1 = 1 ' + @criteriaRoot;
		
	END;

	DECLARE @survey1Leavers NVARCHAR(MAX) = N'
	SELECT
		COUNT(*) AS CountRows
	FROM [dbo].[FactCodingResponse] fct
	INNER JOIN dbo.DimTurnover dt ON fct.DimTurnoverKey = dt.GroupKey
	' + @whereCorrelation + N' 
		AND SurveyKey = ' + @SurveyKey + N'
		AND dt.CodingResponseID = 1';
	
	DELETE @count;

	INSERT INTO @count EXEC sp_executesql @survey1Leavers;

	IF (SELECT CountRows FROM @count) = 0
	BEGIN
		SELECT * FROM #results;
		RETURN
	END;

	
	DECLARE @categoryCriteria NVARCHAR(MAX) = N'';

	IF @Category = 'All'
		SET @categoryCriteria = ''
	ELSE
		SET @categoryCriteria = ' AND CategoryID IN (' + @Category + N')';
	
	DECLARE @survey1DataPID NVARCHAR(MAX) = N'
	SELECT DISTINCT
		PID
	FROM [dbo].[FactCodingResponse] fct
	' + @whereCorrelation + ' 
		AND SurveyKey = ' + @SurveyKey + N' 
		AND OPZScore IS NOT NULL
		' + @categoryCriteria

	
	DROP TABLE IF EXISTS #PIDs;

    CREATE TABLE #PIDs
    (
		ID	INT IDENTITY(1,1),
		PID	BIGINT
    );

    CREATE CLUSTERED INDEX CI_#PIDs ON #PIDs(ID);
      
    INSERT INTO #PIDs
    EXEC sp_executesql @survey1DataPID;

	-- If no Data in Survey 1 that matches the criteria
    IF (SELECT COUNT(*) FROM #PIDs) = 0 
    BEGIN
		SELECT * FROM #results
		RETURN
    END

	DECLARE @survey1Data NVARCHAR(MAX) = N'
	SELECT DISTINCT
		RespondentID,
		PID,
		OPZScore
    FROM [dbo].[FactCodingResponse] fct
    ' + @whereCorrelation + N' 
        AND SurveyKey = ' + @SurveyKey + N'
        AND OPZScore IS NOT NULL';

	PRINT @survey1Data

	DECLARE @survey1TurnoverData NVARCHAR(MAX) = N'
	SELECT DISTINCT
		RespondentID,
		dt.CodingResponseID AS Turnover
    FROM [dbo].[FactCodingResponse] fct
	INNER JOIN dbo.DimTurnover dt ON fct.DimTurnoverKey = dt.GroupKey
    ' + @whereCorrelation + N' 
        AND SurveyKey = ' + @SurveyKey + N'
        AND dt.CodingResponseID IN (0,1)';

	--EXEC sp_executesql @survey1TurnoverData

	-- We only need to check if the Respondent count meets the minimum requirement
    
	DECLARE 
        @PIDs		NVARCHAR(MAX) = N'',
        @PIDsCreate	NVARCHAR(MAX) = N'';

	-- Construct the Pivot Items
    SELECT 
		@PIDs		= @PIDs + QUOTENAME(PID) + ',',
		@PIDsCreate	= @PIDsCreate + QUOTENAME(PID) + ' DECIMAL(18,5),'   
    FROM
    (
		SELECT PID 
		FROM #PIDs
    )sub;

    SET @PIDs		= LEFT(@PIDs,LEN(@PIDs) - 1);
    SET @PIDsCreate	= LEFT(@PIDsCreate,LEN(@PIDsCreate) - 1);
    
	DECLARE @pivotedSurvey1 NVARCHAR(MAX) = N'
    DROP TABLE IF EXISTS ' + @survey1Table + N'

    CREATE TABLE ' + @survey1Table + N'
    (
		RespondentID NVARCHAR(100),
		' +  @PIDsCreate + N'
    );
	CREATE CLUSTERED INDEX CI_' + @survey1Table + N' ON ' + @survey1Table + N'(RespondentID);


    INSERT INTO ' + @survey1Table + N' WITH (TABLOCK)
    SELECT RespondentID,' +  @PIDs + N'  
    FROM
    (
		' + @survey1Data + N'
    )Sourcedata
    PIVOT
    (  
		AVG(OPZScore)
		FOR PID IN (' + @PIDs + N')  
    ) AS PivotTable
	OPTION (MAXDOP 8)';

    EXEC sp_executesql @pivotedSurvey1
	--survey1TurnoverData


	DECLARE @Respondents NVARCHAR(MAX) = N'
    SELECT TOP 150 RespondentID 
    FROM ' + @survey1Table;
      
    DECLARE @Respondentscount TABLE
    (
		RespondentID NVARCHAR(100)
    );

    INSERT INTO @Respondentscount
    EXEC sp_executesql @Respondents
       
    IF (SELECT COUNT(*) FROM @Respondentscount) < 150
    BEGIN
        SELECT * FROM #results;
        RETURN;
    END
	
	DECLARE 
		@OPCorrelation NVARCHAR(MAX) = '',
		@OPColumns NVARCHAR(MAX) = '',
		@RespondentCount NVARCHAR(MAX) = N'';

	SELECT 
		@OPCorrelation = @OPCorrelation + N'
		IIF 
		(	
			StDevP
			(
				IIF
					(
						Turnover IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
						NULL,
						1.0 * Turnover
					)
			) * 
			StDevP
			(
				IIF
					(
						Turnover IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
						NULL,
						' + QUOTENAME(PID) + N'
					)
			) = 0,
			NULL,
			IIF
			(
				COUNT(Turnover) < 25 OR COUNT(' + QUOTENAME(PID) + N') < 25,
				999,
				(
					Avg
					(
						IIF
						(
							Turnover IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
							NULL,
							1.00 * Turnover
						) * 
						IIF
						(
							Turnover IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
							NULL,
							' + QUOTENAME(PID) + N'
						)
					) - 
					(
						Avg
						(
							IIF
							(
								Turnover IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
								NULL,
								1.00 * Turnover
							)
						) * 
						Avg
						(
							IIF
							(
								Turnover IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
								NULL,
								' + QUOTENAME(PID) + N'
							)
						)
					)
				) 
				/ 
				(
					StDevP
					(
						IIF
							(
								Turnover IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
								NULL,
								1.00 * Turnover
							)
					) * 
					StDevP
					(
						IIF
							(
								Turnover IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
								NULL,
								' + QUOTENAME(PID) + N'
							)
					)
				)
			)
		) AS ' + QUOTENAME('Turnover~' + CAST(PID AS NVARCHAR(10)))+ N',',
		@RespondentCount        = @RespondentCount + N'
        COUNT
        (
            IIF
            (
                Turnover IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
                NULL,
                Turnover
            )
        ) AS ' + QUOTENAME(N'Turnover~' + CAST(PID AS NVARCHAR(10))) + N',',
		@OPColumns		= @OPColumns + QUOTENAME(N'Turnover~' + CAST(PID AS NVARCHAR(10))) + N','
	FROM #PIDs;


	SET @OPCorrelation	= LEFT(@OPCorrelation,LEN(@OPCorrelation) - 1);
	SET @OPColumns		= LEFT(@OPColumns,LEN(@OPColumns) - 1);
	SET @RespondentCount		= LEFT(@RespondentCount,LEN(@RespondentCount) - 1);

	DECLARE	@final NVARCHAR(MAX) = N'
	SELECT 
		REPLACE(SUBSTRING(PID,1,CHARINDEX(''~'',PID) - 1),'''','''') AS RecordLabel1,
		CAST(REPLACE(SUBSTRING(PID,CHARINDEX(''~'',PID) + 1,LEN(PID)),'''','''') AS BIGINT) AS PID,
		PearsonsR
	FROM
	(
		SELECT 
		' + @OPCorrelation + N'
		FROM
		( 
			' + @survey1TurnoverData + N'
		)alldata
		INNER JOIN ' + @survey1Table + N' temp ON temp.RespondentID = alldata.RespondentID
	)correlation
	unpivot
	(
		PearsonsR for PID in
		(
			' + @OPColumns + N'
		)
	)unpvt'

	DECLARE @CorrelationResults TABLE
	(
		RecordLabel1	NVARCHAR(100),
		PID				BIGINT,
		PearsonsR		DECIMAL(18,5)

	);
	DECLARE @CorrelationRespondent TABLE
	(
		RecordLabel1	NVARCHAR(100),
		PID				BIGINT,
		RespondentCount BIGINT

	);
	DECLARE @CorrelationResultsFinal TABLE
	(
		PID							BIGINT,
		RespondentCount				BIGINT,
		PearsonsR					DECIMAL(18,5),
		IsStatisticallySignificant	BIT

	);
	INSERT INTO @CorrelationResults
	EXEC sp_executesql @final

	DECLARE @finalRespondentCount NVARCHAR(MAX) = N'
    SELECT 
		REPLACE(SUBSTRING(PID,1,CHARINDEX(''~'',PID) - 1),'''','''') AS RecordLabel1,
        REPLACE(SUBSTRING(PID,CHARINDEX(''~'',PID) + 1,LEN(PID)),'''','''') AS PID,
        RespondentCount
    FROM
    (
        SELECT 
        ' + @RespondentCount + N'
        FROM
        ( 
            ' + @survey1TurnoverData + N'
        )alldata
        INNER JOIN ' + @survey1Table + N' temp ON temp.RespondentID = alldata.RespondentID
    )correlation
    unpivot
    (
        RespondentCount for PID in
        (
			' + @OPColumns + N'
        )
    )unpvt
	--OPTION (MAXDOP 8);';

	PRINT @finalRespondentCount
	INSERT INTO @CorrelationRespondent
	EXEC sp_executesql @finalRespondentCount

	INSERT INTO @CorrelationResultsFinal
	SELECT
		PID							= cr.PID
		,RespondentCount			= cc.RespondentCount
		,PearsonsR					= cr.PearsonsR
		,IsStatisticallySignificant = IIF
										(
											ABS(cr.PearsonsR) >= crit.CriticalValue,
											1,
											0
										)
	FROM @CorrelationResults cr
	INNER JOIN @CorrelationRespondent cc ON cr.PID = cc.PID
	OUTER APPLY dbo.tvf_GetPearsonCriticalValue('95',cc.RespondentCount - 2) crit

	-- Section: Retrieve data from OLAP

	DECLARE @questionkeys NVARCHAR(MAX) = N'';
	DECLARE 
		@groupscriteria	NVARCHAR(MAX) = N'',
		@SurveyCriteria	NVARCHAR(MAX) = N'{[Dim Survey].[Survey Key].&[' + @SurveyKey + N']}',
		@where			NVARCHAR(MAX) = N'';

	IF @Category <> 'All' AND @Category <> ''
	BEGIN
		SELECT @questionkeys = @questionkeys + N'
		[Dim OP Items].[Category].[Category].&[' + c.Category + N'],'
		FROM string_split(@Category,N',')a
		INNER JOIN dbo.Category c ON c.CategoryId = CAST(a.[value] AS INT);

		SET @questionkeys = N'{' + LEFT(@questionkeys,LEN(@questionkeys) - 1) + N'}';
	END;

	IF (@Population = 'All'  OR @Population = '')
	BEGIN
		SET @groupscriteria = N'';
	END
	ELSE 
	BEGIN

		DECLARE @columns NVARCHAR(MAX) = N'';

		DECLARE @keys AS TABLE
		(
			GroupKey	INT,
			DimColumn	NVARCHAR(500)
		);
			
		INSERT INTO @keys
		SELECT 
			s.value AS GroupKey,
			dbo.svfRemoveNonAlphaCharacters(b.RootCQ) AS DimColumn
		FROM string_split(@Population,N',') s
		OUTER APPLY dbo.tvf_GetCQRoot(CAST(s.[value] AS INT))B

		DECLARE @dims AS TABLE
		(
			ID int IDENTITY(1,1),
			DimColumn NVARCHAR(500)
		);

		INSERT INTO @dims
		SELECT DISTINCT DimColumn FROM @keys;

		DECLARE 
			@index		INT				= 1,
			@maxIndex	INT				= (SELECT MAX(ID) FROM @dims),
			@DimTable	NVARCHAR(MAX)	= N'',
			@GroupKeys	NVARCHAR(MAX)	= N'';

		WHILE @index <= @maxIndex
		BEGIN
			
			SELECT 
				@DimTable = DimColumn
			FROM @dims
			WHERE ID = @index;

			DECLARE @Caption NVARCHAR(100) = (SELECT Caption FROM staging.CQList WHERE dimTable = @DimTable);
			
			SET @GroupKeys = '';

			SELECT @GroupKeys = @GroupKeys + N'[' + @Caption + N'].[' + @Caption + N' Hierarchy].&[' + CAST(GroupKey AS NVARCHAR(10)) + N'],'
			FROM @Keys
			WHERE DimColumn = @DimTable;

			SET @GroupKeys = LEFT(@GroupKeys,LEN(@GroupKeys) - 1);
			
			SET @groupscriteria = @groupscriteria + N'{' + @GroupKeys + '},';
				
			SET @index += 1;
		END
	END;
	 

	IF @groupscriteria = N'' AND @questionkeys = N''
	BEGIN
		SET @where = N'
		WHERE 
		(' 
			+ @SurveyCriteria + N'
		)';
	END
	ELSE
	BEGIN
		
		IF @groupscriteria <> N''
		BEGIN
			SET @groupscriteria = LEFT(@groupscriteria,LEN(@groupscriteria) - 1);
			SET @groupscriteria = N',' + @groupscriteria;
		END;
		
		IF @questionkeys <> N''
			SET @questionkeys = N',' + @questionkeys;

		PRINT @groupscriteria
		SET @where = N'
		WHERE
		(' 
			+ @SurveyCriteria + @groupscriteria + @questionkeys + N'
		);'
	END;

	
	--PRINT @where
	
	DECLARE @sql NVARCHAR(MAX) = N'';
	
	SET @sql = N'
	SELECT
	{  
   		[Measures].[NSizeCutOff],
		[Measures].[Favorable Score],
		[Measures].[Neutral Score],
		[Measures].[Unfavorable Score],
		[Measures].[Favorable],
		[Measures].[Neutral] ,
		[Measures].[Unfavorable],
		[Measures].[FavorableTurnoverPercent],
		[Measures].[UnfavorableTurnoverPercent]
	} ON COLUMNS, 
	{(
		[Dim OP Items].[PID].[PID]
		* [Dim OP Items].[Item Text].[Item Text]
		* [Dim OP Items].[Category Item Text Hierarchy].[Category]
	)} DIMENSION PROPERTIES MEMBER_CAPTION ON ROWS 
	FROM [OpinionInsightsDynamicDim]
	' + @where;


	DROP TABLE IF EXISTS #OlapData;

	CREATE TABLE #OlapData
	(
		PID							NTEXT,
		ItemText					NVARCHAR(600),
		Category					NVARCHAR(600),
		NSizeCutOff					BIGINT,
		FavorableScore				BIGINT,
		NeutralScore				BIGINT,
		UnfavorableScore			BIGINT,
		FavorablePercentage			FLOAT,
		NeutralPercentage			FLOAT,
		UnfavorablePercentage		FLOAT,
		FavorableTurnOverRatio		FLOAT,
		UnfavorableTurnOverRatio	FLOAT
	);

	DECLARE @linkedserver NVARCHAR(100) = QUOTENAME(DB_NAME());
	
	DECLARE @ssasquery NVARCHAR(MAX) = N'
	INSERT INTO #OlapData
	EXEC (''' + @sql + ''') AT ' + @linkedserver + '
	';
	
	EXEC sp_executesql @ssasquery;

	DROP TABLE IF EXISTS #CubeResults;

	CREATE TABLE #CubeResults
	(
		PID								BIGINT,
		ItemText						NVARCHAR(500),
		Category						NVARCHAR(500),
		NSizeCutOff						FLOAT,
		FavorableResponse				FLOAT,
		UnfavorableResponse				FLOAT,
		NeutralResponse					FLOAT,
		FavorablePercentage				DECIMAL(18,5),
		NeutralPercentage				DECIMAL(18,5),
		UnfavorablePercentage			DECIMAL(18,5),
		UnfavorableTurnOverRatio		DECIMAL(18,5),
		FavorableTurnOverRatio			DECIMAL(18,5),
		UnfavorableTurnOverRatioFiller	DECIMAL(18,5),
		FavorableTurnOverRatioFiller	DECIMAL(18,5)
	);

	SET @sql = N'
	;with CTE AS
	(
		SELECT 
			PID							= CAST(CAST(PID AS NVARCHAR(20)) AS BIGINT)
			,ItemText					= ItemText
			,Category					= Category
			,NSizeCutoff				= NSizeCutoff
			,FavorableResponse			= CAST(FavorableScore AS FLOAT)
			,UnfavorableResponse		= CAST(UnfavorableScore AS BIGINT)
			,NeutralResponse			= CAST(NeutralScore AS BIGINT)
			,FavorablePercentage		= FavorablePercentage
			,NeutralPercentage			= NeutralPercentage
			,UnfavorablePercentage		= UnfavorablePercentage
			,UnfavorableTurnOverRatio	= UnfavorableTurnOverRatio
			,FavorableTurnOverRatio		= FavorableTurnOverRatio
		FROM #OlapData
	)
	SELECT 
		*
		,UnfavorableTurnOverRatioFiller = ROUND((1 - UnfavorableTurnOverRatio),4)
		,FavorableTurnOverRatioFiller	= ROUND((1 - FavorableTurnOverRatio),4) 
	FROM CTE;
	'
	INSERT INTO #CubeResults
	EXEC sp_executesql @sql;

	
	DECLARE @Cleanup NVARCHAR(100) = N'';

	SET @Cleanup = N'
	DROP TABLE IF EXISTS ' + @globaltable + N';
	DROP TABLE IF EXISTS ' + @survey1Table;
	
	EXEC sp_executesql @Cleanup;

	IF NOT EXISTS (SELECT 1 FROM dbo.CorrelationGroupFilter WHERE GroupFilter = @groupsorted)
		INSERT INTO dbo.CorrelationGroupFilter VALUES(@groupsorted);

	DECLARE @CorrelationGroupFilterID INT = (SELECT CorrelationGroupFilterID FROM dbo.CorrelationGroupFilter WHERE GroupFilter = @groupsorted);

	INSERT INTO dbo.CorrelationTurnoverCacheResult
	SELECT
		CorrelationGroupFilterID		= (SELECT CorrelationGroupFilterID FROM dbo.CorrelationGroupFilter WHERE GroupFilter = @groupsorted)
		,SurveyKey						= CAST(@SurveyKey AS INT)
		,PID							= c.PID
		,CategoryID						= cat.CategoryID
		,NSizeCutOff					= c.NSizeCutOff
		,FavorableResponse				= c.FavorableResponse
		,UnfavorableResponse			= c.UnfavorableResponse
		,NeutralResponse				= c.NeutralResponse
		,FavorablePercentage			= c.FavorablePercentage
		,NeutralPercentage				= c.NeutralPercentage
		,UnfavorablePercentage			= c.UnfavorablePercentage
		,UnfavorableTurnOverRatio		= c.UnfavorableTurnOverRatio
		,FavorableTurnOverRatio			= c.FavorableTurnOverRatio
		,UnfavorableTurnOverRatioFiller = c.UnfavorableTurnOverRatioFiller
		,FavorableTurnOverRatioFiller	= c.FavorableTurnOverRatioFiller
		,CorrelationStrength			= ISNULL(ROUND(cr.PearsonsR,2),999)
		,CorrelationStrengthState		= ST.PearsonsRStates
		,CorrelationRespondentCount		= cr.RespondentCount
		,IsStatisticallySignificant		= cr.IsStatisticallySignificant
		,CriticalValue					= crit.CriticalValue
		,CategoryParam					= @Category
	FROM #CubeResults c
	INNER JOIN dbo.Category cat ON cat.Category = c.Category
	LEFT JOIN @CorrelationResultsFinal cr ON c.PID = cr.PID
	INNER JOIN 
	(
		SELECT DISTINCT di.PID
		FROM dbo.DimCategoryItem di
		INNER JOIN [corr].[CorrelationMapping] lib ON di.ScaleLabel = lib.ScaleLabel
	)lib ON lib.PID = c.PID
	OUTER APPLY dbo.tvf_GetPearsonCriticalValue('95',cr.RespondentCount - 2) crit
	CROSS APPLY reporting.tvfGetPearsonsRStates(ROUND(ISNULL(ROUND(cr.PearsonsR,2),999),2),crit.CriticalValue)  ST 

	SELECT
		PID								= tov.PID
		,ItemText						= ci.ItemText
		,Category						= c.Category
		,NSizeCutOff					= tov.NSizeCutOff
		,FavorableResponse				= tov.FavorableResponse
		,UnfavorableResponse			= tov.UnfavorableResponse
		,NeutralResponse				= tov.NeutralResponse
		,FavorablePercentage			= tov.FavorablePercentage
		,NeutralPercentage				= tov.NeutralPercentage
		,UnfavorablePercentage			= tov.UnfavorablePercentage
		,UnfavorableTurnOverRatio		= tov.UnfavorableTurnOverRatio
		,FavorableTurnOverRatio			= tov.FavorableTurnOverRatio
		,UnfavorableTurnOverRatioFiller = tov.UnfavorableTurnOverRatioFiller
		,FavorableTurnOverRatioFiller	= tov.FavorableTurnOverRatioFiller
		,CorrelationStrength			= ROUND(tov.CorrelationStrength,2)
		,CorrelationStrengthState		= tov.CorrelationStrengthState
		,CorrelationRespondentCount		= tov.CorrelationRespondentCount
		,IsStatisticallySignificant		= tov.IsStatisticallySignificant
		,CriticalValue					= tov.CriticalValue
	FROM dbo.CorrelationTurnoverCacheResult tov
	INNER JOIN dbo.DimCategoryItem ci ON tov.PID = ci.PID
	INNER JOIN dbo.Category c ON c.CategoryID = tov.CategoryID
	WHERE tov.CorrelationGroupFilterID = @CorrelationGroupFilterID
		AND tov.SurveyKey = CAST(@SurveyKey AS INT)
		AND tov.FavorablePercentage IS NOT NULL
		AND (tov.FavorableTurnOverRatio IS NOT NULL OR tov.UnfavorableTurnOverRatio IS NOT NULL)
		AND CategoryParam = @Category
	ORDER BY tov.CorrelationStrength ASC
END;
GO