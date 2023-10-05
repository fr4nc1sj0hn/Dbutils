/**
      Summary:
            Calculate the Correlation Coefficient for all available categories and the Opinion Items of a Selected Category
      Example:
            EXEC corr.[uspCorrelateOPToOP]
                  @Population		= 'All',
                  @FirstSurveyKey	= '1',
                  @SecondSurveyKey  = '2',
				  @Category1		= 'Dummy',
				  @Category2		= 'Leadership',
                  @SessionID		= ''


			EXEC corr.[uspCorrelateOPToOP]
                  @Population		= 'All',
                  @FirstSurveyKey	= '1',
                  @SecondSurveyKey  = '2',
				  @Category1		= 'Leadership',
				  @Category2		= 'Leadership',
                  @SessionID		= ''
      Returns: Correlation Matrix


      Change History
      ==============================================================
	  04/06/2020	FRANC583		Initial Version
	  05/01/2020	FRANC583		Handling single quotes in Category
	  05/04/2020	FRANC583		Use PIDs instead of OP Number
	  05/14/2020    ALEXA749        Updated Category 2 to be truncated. Workaround for Dundas
	  05/16/2020	FRANC583		Support for other Demographics
	  07/31/2020    ALEXA749        Add PearsonStates for color coding in dashboard
	  08/11/2020	FRANC583		Store Results to a Table
	  02/19/2021	FRANC583		Single Fact Table
**/
CREATE PROCEDURE [corr].[uspCorrelateOPToOP]
@Population			NVARCHAR(1000) = 'All',
@FirstSurveyKey		NVARCHAR(3),
@SecondSurveyKey	NVARCHAR(3),
@Category1			NVARCHAR(100),
@Category2			NVARCHAR(100),
@SessionID			NVARCHAR(100)= ''
AS
BEGIN
	SET NOCOUNT ON;

	
	DECLARE 
        @SurveyKey1		NVARCHAR(MAX)	= @FirstSurveyKey,
        @SurveyKey2		NVARCHAR(MAX)	= @SecondSurveyKey,
        @Group1			NVARCHAR(MAX)	= @Population,
        @SurveyName1	NVARCHAR(100)	= (SELECT top 1 SurveyName FROM dbo.dimSurvey WHERE SurveyKey = CAST(@FirstSurveyKey AS INT)),
        @SurveyName2	NVARCHAR(100)	= (SELECT top 1 SurveyName FROM dbo.dimSurvey WHERE SurveyKey = CAST(@SecondSurveyKey AS INT)),
		@CategoryID1	INT				= (SELECT CategoryId FROM dbo.Category WHERE Category = @Category1),
		@CategoryID2	INT				= (SELECT CategoryId FROM dbo.Category WHERE Category = @Category2);

	-- For the cache results.
	DECLARE @groupsorted NVARCHAR(MAX) = N''
	SELECT @groupsorted = @groupsorted + [value] + N',' FROM 
	(
		SELECT [value] FROM  string_split(@Population,N',')val
	)A
	ORDER BY [value];

	SET @groupsorted = LEFT(@groupsorted,LEN(@groupsorted) - 1);
	
	DECLARE @GroupFilterID BIGINT = (SELECT dbo.svfGetGroupFilterID(@groupsorted));

	IF EXISTS 
	(
		SELECT 1 FROM dbo.CorrelationOPToOPCacheResult 
		WHERE SurveyKey1 = CAST(@FirstSurveyKey AS INT) 
			AND SurveyKey2 = CAST(@SecondSurveyKey AS INT) 
			AND CorrelationGroupFilterID = @GroupFilterID
			AND CategoryID1 = @CategoryID1
			AND  CategoryID2 = @CategoryID2
	)
	BEGIN
		SELECT
			SurveyName1 = REPLACE(@SurveyName1,'''','''''')
			,RecordLabel1 = c1.ItemText
			,SurveyName2 = REPLACE(@SurveyName2,'''','''''')
			,RecordLabel2 = c2.ItemText
			,Category1 = @Category1
			,Category2 = @Category2
			,RespondentCount
			,PearsonsR				
			,IsStatisticallySignificant
			,PearsonsRStates
		FROM dbo.CorrelationOPToOPCacheResult r
		INNER JOIN dbo.DimCategoryItem c1 ON r.PID1 = c1.PID
		INNER JOIN dbo.DimCategoryItem c2 ON r.PID2 = c2.PID
		WHERE r.CorrelationGroupFilterID = @GroupFilterID
			AND r.SurveyKey1 = CAST(@FirstSurveyKey AS INT)
			AND r.SurveyKey2 = CAST(@SecondSurveyKey AS INT)
			AND CategoryID1 = @CategoryID1
			AND  CategoryID2 = @CategoryID2
		RETURN;
	END;

	DECLARE @globaltable NVARCHAR(100) = N'##' + REPLACE(CAST(NEWID() AS NVARCHAR(100)),'-','');
	DECLARE @survey1Table NVARCHAR(100) = @globaltable + N'_Survey1';

	DECLARE @results TABLE
	(	
		SurveyName1		NVARCHAR(100),
		RecordLabel1	NVARCHAR(100),
		SurveyName2		NVARCHAR(100),
		RecordLabel2	NVARCHAR(100),
		RespondentCount BIGINT,
		PearsonsR		DECIMAL(5,3)
	);
	DECLARE @resultsFinal TABLE
	(     
		SurveyName1					NVARCHAR(100),
		RecordLabel1				NVARCHAR(100),
		SurveyName2					NVARCHAR(100),
		RecordLabel2				NVARCHAR(100),
		Category1					NVARCHAR(100),
		Category2					NVARCHAR(100),
		RespondentCount				BIGINT,
		PearsonsR					DECIMAL(5,3),
		IsStatisticallySignificant	BIT,
		PearsonsRStates				INT
	);

	DECLARE @resultsRespondentCount TABLE
	(     
		RecordLabel1	NVARCHAR(100),
		RecordLabel2	NVARCHAR(100),
		RespondentCount BIGINT,
		INDEX IX3 CLUSTERED(RecordLabel1,RecordLabel2)
	);

	DECLARE
		@loc_SurveyKey1		NVARCHAR(MAX) = IIF((@SurveyKey1 = 'All' OR @SurveyKey1 = ''),'SurveyKey IS NOT NULL','SurveyKey = ' + @SurveyKey1),
		@loc_SurveyKey2		NVARCHAR(MAX) = IIF((@SurveyKey2 = 'All' OR @SurveyKey2 = ''),'SurveyKey IS NOT NULL','SurveyKey = ' + @SurveyKey2),
		@loc_Groups   		NVARCHAR(MAX) = @Group1,
		@SameSurvey			BIT = 1
	
	IF @Category1 = 'Dummy' OR @Category2 = 'Dummy'
	BEGIN
		-- Dundas WorkAround
		SELECT
			@SurveyName1	AS SurveyName1,
			'Question' + CAST(v.valueId as NVARCHAR(2))		AS RecordLabel1,
			@SurveyName2	AS SurveyName2,
			'Question' + CAST(v2.valueId as NVARCHAR(2))		AS RecordLabel2,
			'Category'		AS Category1,
			'Category'		AS Category2,
			0				AS RespondentCount,
			0				AS PearsonsR,
			0				AS IsStatisticallySignificant,
			0               AS PearsonsRStates
		FROM (VALUES (1), (2), (3), (4), (5), (6), (7), (8), (9), (10), (11), (12), (13), (14), (15)) v(valueId)
		CROSS JOIN (VALUES (1), (2), (3), (4), (5)) v2(valueId)
		RETURN;
	END

	DECLARE 
		@groupscriteria NVARCHAR(MAX) = N'',
		@where			NVARCHAR(MAX) = N'';
	
    DECLARE @sql NVARCHAR(MAX) = N'';

    IF (@Group1 = '') OR (@FirstSurveyKey = 'All' OR @FirstSurveyKey = '') OR (@SecondSurveyKey = 'All' OR @SecondSurveyKey = '')
    BEGIN
            SELECT * FROM @resultsFinal;
            RETURN;
    END
     
	
	DROP TABLE IF EXISTS #childkeys
	-- Generate the GroupKeys recursively
    CREATE TABLE #childkeys
    (
        GroupKey 		BIGINT,
		ParentCQName	NVARCHAR(1000)
    );

	CREATE CLUSTERED INDEX CI_#childkeys ON #childkeys(GroupKey);
	CREATE NONCLUSTERED INDEX NCI_#childkeys ON #childkeys(ParentCQName) INCLUDE(GroupKey);
        
	IF @Group1 = 'All'
    BEGIN
		SET @where = N'WHERE 1 = 1 ';
    END
    ELSE
    BEGIN
		DECLARE @criteriaRoot NVARCHAR(MAX) = N'';

		DECLARE @GroupKeysRoot TABLE
		(
			ID INT IDENTITY(1,1),
			GroupKey BIGINT
		);
		DECLARE @GroupKeysNotRoot TABLE
		(
			ID INT IDENTITY(1,1),
			GroupKey BIGINT
		);
		
		INSERT INTO @GroupKeysRoot
		SELECT [value] AS GroupKey 
		FROM string_split(@loc_Groups,',') g
		INNER JOIN dbo.dimGroup dg ON g.value = dg.GroupKey 
		WHERE ParentGroupKey IS NULL;
		
		SELECT 
			@criteriaRoot	= @criteriaRoot + N'
								Dim' + dbo.svfRemoveNonAlphaCharacters(ParentCQName) + N'Key <> -1 AND'
		FROM @GroupKeysRoot g
		INNER JOIN dbo.dimGroup dg ON g.GroupKey = dg.GroupKey

		IF @criteriaRoot <> N''
			SET @criteriaRoot = N' AND ' + LEFT(@criteriaRoot,LEN(@criteriaRoot) - 3);

		INSERT INTO @GroupKeysNotRoot
		SELECT [value] AS GroupKey 
		FROM string_split(@loc_Groups,',') g
		INNER JOIN dbo.dimGroup dg ON g.value = dg.GroupKey 
		WHERE ParentGroupKey IS NOT NULL;
		
		DECLARE @insertKeys NVARCHAR(MAX) = N'';

		SELECT @insertKeys = @insertKeys + N'
			INSERT INTO #childkeys EXEC dbo.uspGenerateGroups @Group = ' + CAST(GroupKey AS NVARCHAR(10)) + N';'
		FROM @GroupKeysNotRoot;

		EXEC sp_executesql @insertKeys;

		IF (SELECT COUNT(*) FROM #childkeys) = 0 AND (@criteriaRoot = N'')
		BEGIN
			SELECT * FROM @resultsFinal;
			RETURN;
		END
		DECLARE @Groups NVARCHAR(MAX) = N''

		SELECT @Groups = @Groups + N'
		INNER JOIN (SELECT GroupKey FROM #childkeys WHERE ParentCQName = ''' + ParentCQName + N''') ' + dbo.svfRemoveNonAlphaCharacters(ParentCQName) + N' ON fct.Dim' + dbo.svfRemoveNonAlphaCharacters(ParentCQName) + N'Key = ' + dbo.svfRemoveNonAlphaCharacters(ParentCQName) + N'.GroupKey'
		FROM 
		(
			SELECT DISTINCT ParentCQName FROM #childkeys
		)a;

		SET @where = @Groups + N'
		WHERE 1 = 1 ' + @criteriaRoot;
		
	END;

	DECLARE @survey1DataPID NVARCHAR(MAX) = N'
	SELECT DISTINCT
		PID
	FROM [dbo].[FactCodingResponse] fct
	' + @where + ' 
		AND SurveyKey = ' + @SurveyKey1 + N' 
		AND OPZScore IS NOT NULL
		AND Category = ''' + REPLACE(@Category1,'''','''''') + '''';

	
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
		SELECT * FROM @resultsFinal;
		RETURN
    END

	DECLARE @survey1Data NVARCHAR(MAX) = N'
	SELECT DISTINCT
		RespondentID,
		PID,
		OPZScore
    FROM [dbo].[FactCodingResponse] fct
    ' + @where + N' 
        AND ' + @loc_SurveyKey1 + N'
        AND OPZScore IS NOT NULL';


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
	OPTION (MAXDOP 8)'

    EXEC sp_executesql @pivotedSurvey1


	DECLARE @Respondents NVARCHAR(MAX) = N'
    SELECT TOP 150 RespondentID 
    FROM ' + @survey1Table;
      
	DECLARE @count TABLE
	(
		RespondentID NVARCHAR(100)
	);

	INSERT INTO @count
	EXEC sp_executesql @Respondents

            
	IF (SELECT COUNT(*) FROM @count) < 150
	BEGIN
		SELECT * FROM @resultsFinal;
		RETURN;
	END


	DECLARE 
		@Survey2Source NVARCHAR(MAX) = N'',
		@CategorySource NVARCHAR(MAX) = N'';


	IF @SurveyKey1 = @SurveyKey2
	BEGIN
		SET @Survey2Source = N'
		SELECT
			RespondentID AS RecordID,
			PID,
			OPZScore
		FROM [dbo].[FactCodingResponse] fct
		' + @where + N'
			AND ' + @loc_SurveyKey2 + N' 
			AND OPZScore IS NOT NULL
			AND Category = ''' + REPLACE(@Category2,'''','''''') + '''';

		SET @CategorySource = N'
		SELECT DISTINCT
			PID
		FROM [dbo].[FactCodingResponse] fct
		' + @where + N'
			AND ' + @loc_SurveyKey2 + N' 
			AND OPZScore IS NOT NULL
			AND Category = ''' + REPLACE(@Category2,'''','''''') + '''';
	END
	ELSE
	BEGIN
		SET @Survey2Source = N'
		SELECT 
			s1.RecordID,
			fct2.PID,
			fct2.OPZScore
		FROM
		(
			SELECT
				RespondentID AS RecordID
            FROM ' + @survey1Table + N'
		)s1
		INNER JOIN [dbo].[FactCodingResponse] fct2 ON s1.RecordID = fct2.RespondentID
		WHERE OPZScore IS NOT NULL AND fct2.SurveyKey = ' + @SurveyKey2 + N'
		AND Category = ''' + REPLACE(@Category2,'''','''''') + '''';

		SET @CategorySource = N'
		SELECT DISTINCT 
			fct2.PID
		FROM
		(
			SELECT
				RespondentID AS RecordID
            FROM ' + @survey1Table + N'
		)s1
		INNER JOIN [dbo].[FactCodingResponse] fct2 ON s1.RecordID = fct2.RespondentID
		WHERE OPZScore IS NOT NULL AND fct2.SurveyKey = ' + @SurveyKey2 + N'
		AND Category = ''' + REPLACE(@Category2,'''','''''') + '''';;
	END

	DROP TABLE IF EXISTS #CategoriesSurvey2;

	CREATE TABLE #CategoriesSurvey2
	(
		ID INT IDENTITY(1,1),
		PID BIGINT
	);


	INSERT INTO #CategoriesSurvey2
	EXEC sp_executesql @CategorySource;

	IF (SELECT COUNT(*) FROM #CategoriesSurvey2) = 0 
	BEGIN
		SELECT * FROM @resultsFinal;
		RETURN
	END;

	DECLARE 
		@OPs1					NVARCHAR(MAX)	= N'',
		@OPs1Create				NVARCHAR(MAX)	= N'',
		@OPCategoryCorrelation	NVARCHAR(MAX)	= N'',
		@OPCategoryColumns		NVARCHAR(MAX)	= N'',
		@OP1					NVARCHAR(10)	= N'';

	SELECT 
		@OPs1				= @OPs1 + QUOTENAME(PID) + ',',
		@OPs1Create			= @OPs1Create + QUOTENAME(PID) + ' DECIMAL(18,5),'	
	FROM
	(
		SELECT DISTINCT PID
		FROM #CategoriesSurvey2
	)sub;


	SET @OPs1				= LEFT(@OPs1,LEN(@OPs1) - 1);
	SET @OPs1Create			= LEFT(@OPs1Create,LEN(@OPs1Create) - 1);

		

	DECLARE @pivoted NVARCHAR(MAX) = N'
	DROP TABLE IF EXISTS ' + @globaltable + N'

	CREATE TABLE ' + @globaltable + N'
	(
		RecordID NVARCHAR(100),
		' +  @OPs1Create + N'
	);

	INSERT INTO ' + @globaltable + N'
	SELECT RecordID,' +  @OPs1 + N'  
	FROM
	(
		' + @Survey2Source + N'
	)Sourcedata
	PIVOT
	(  
		AVG(OPZScore)
		FOR PID IN (' + @OPs1 + N')  
	) AS PivotTable
		
	CREATE CLUSTERED COLUMNSTORE INDEX CCI_' + @globaltable + N' ON ' + @globaltable + N';';

	EXEC sp_executesql @pivoted
		
		
	DECLARE 
		@Index		INT = 1,
		@maxindex	INT = (SELECT MAX(ID) FROM #PIDs)

	DECLARE @RespondentCount NVARCHAR(MAX) = N'';
     
	WHILE @Index <= @maxindex
	BEGIN
		SET @OP1 = (SELECT CAST(PID AS NVARCHAR(25)) FROM #PIDs WHERE ID = @Index);

		DECLARE @Survey1Source NVARCHAR(MAX) = N'
		SELECT
			RespondentID AS RecordID,
			' + QUOTENAME(@OP1) + N' AS OPZScore
		FROM ' + @survey1Table + N'
		WHERE ' + QUOTENAME(@OP1) + N' IS NOT NULL';


		SET @OPCategoryCorrelation = '';
		SET @OPCategoryColumns = '';
		SET @RespondentCount = N'';

		SELECT 
			@OPCategoryCorrelation = @OPCategoryCorrelation + N'
			IIF 
			(	
				StDevP
				(
					IIF
						(
							OPZScore IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
							NULL,
							OPZScore
						)
				) * 
				StDevP
				(
					IIF
						(
							OPZScore IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
							NULL,
							' + QUOTENAME(PID) + N'
						)
				) = 0,
				NULL,
				IIF
				(
					COUNT(OPZScore) < 25 OR COUNT(' + QUOTENAME(PID) + N') < 25,
					NULL,
					(
						Avg
						(
							IIF
							(
								OPZScore IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
								NULL,
								OPZScore
							) * 
							IIF
							(
								OPZScore IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
								NULL,
								' + QUOTENAME(PID) + N'
							)
						) - 
						(
							Avg
							(
								IIF
								(
									OPZScore IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
									NULL,
									OPZScore
								)
							) * 
							Avg
							(
								IIF
								(
									OPZScore IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
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
									OPZScore IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
									NULL,
									OPZScore
								)
						) * 
						StDevP
						(
							IIF
								(
									OPZScore IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
									NULL,
									' + QUOTENAME(PID) + N'
								)
						)
					)
				)
			) AS ' + QUOTENAME(@OP1 + '~' + CAST(PID AS NVARCHAR(10)))+ N',',
			@RespondentCount        = @RespondentCount + N'
            COUNT
            (
                IIF
                (
                    OPZScore IS NULL OR ' + QUOTENAME(PID) + N' IS NULL,
                    NULL,
                    OPZScore
                )
            ) AS ' + QUOTENAME(@OP1 + '~' + CAST(PID AS NVARCHAR(10))) + N',',
			@OPCategoryColumns		= @OPCategoryColumns + QUOTENAME(@OP1 + '~' + CAST(PID AS NVARCHAR(10))) + N','
		FROM #CategoriesSurvey2;


		SET @OPCategoryCorrelation	= LEFT(@OPCategoryCorrelation,LEN(@OPCategoryCorrelation) - 1);
		SET @OPCategoryColumns		= LEFT(@OPCategoryColumns,LEN(@OPCategoryColumns) - 1);
		SET @RespondentCount		= LEFT(@RespondentCount,LEN(@RespondentCount) - 1);

		DECLARE	@final NVARCHAR(MAX) = N'
		SELECT 
			''' + REPLACE(@SurveyName1,'''','''''') + N''' AS SurveyName1,
			REPLACE(SUBSTRING(PID,1,CHARINDEX(''~'',PID) - 1),'''','''') AS RecordLabel1,
			''' + REPLACE(@SurveyName2,'''','''''') + N''' AS SurveyName2,
			REPLACE(SUBSTRING(PID,CHARINDEX(''~'',PID) + 1,LEN(PID)),'''','''') AS RecordLabel2,
			NULL AS RespondentCount,
			PearsonsR
		FROM
		(
			SELECT 
			' + @OPCategoryCorrelation + N'
			FROM
			( 
				' + @Survey1Source + N'
			)alldata
			INNER JOIN ' + @globaltable + N' temp ON temp.RecordID = alldata.RecordID
		)correlation
		unpivot
		(
			PearsonsR for PID in
			(
				' + @OPCategoryColumns + N'
			)
		)unpvt'

		INSERT INTO @results
		EXEC sp_executesql @final

		DECLARE @finalRespondentCount NVARCHAR(MAX) = N'
        SELECT 
            REPLACE(SUBSTRING(PID,1,CHARINDEX(''~'',PID) - 1),'''','''') AS RecordLabel1,
            REPLACE(SUBSTRING(PID,CHARINDEX(''~'',PID) + 1,LEN(PID)),'''','''') AS RecordLabel2,
            RespondentCount
        FROM
        (
            SELECT 
            ' + @RespondentCount + N'
            FROM
            ( 
                ' + @Survey1Source + N'
            )alldata
            INNER JOIN ' + @globaltable + N' temp ON temp.RecordID = alldata.RecordID
        )correlation
        unpivot
        (
            RespondentCount for PID in
            (
				' + @OPCategoryColumns + N'
            )
        )unpvt
		OPTION (MAXDOP 8);';

		INSERT INTO @resultsRespondentCount
		EXEC sp_executesql @finalRespondentCount

		SET @Index += 1;
	END
	DECLARE @Cleanup NVARCHAR(100) = N'';

	SET @Cleanup = N'
	DROP TABLE IF EXISTS ' + @globaltable + N';
	DROP TABLE IF EXISTS ' + @survey1Table;

	EXEC sp_executesql @Cleanup

	DROP TABLE IF EXISTS #results;
	
	SELECT DISTINCT
		SurveyKey1					= CAST(@FirstSurveyKey AS INT)
		,SurveyKey2					= CAST(@SecondSurveyKey AS INT)
		,PID1						= CAST(r.RecordLabel1 AS BIGINT) 
		,PID2						= CAST(r.RecordLabel2 AS BIGINT) 
		,SurveyName1                = r.SurveyName1
		,RecordLabel1               = c1.ItemText
		,SurveyName2                = r.SurveyName2
		,RecordLabel2               = c2.ItemText
		,Category1                  = @Category1
		,Category2                  = @Category2
		,RespondentCount            = resp.RespondentCount
		,PearsonsR                  = CASE
							            WHEN r.PearsonsR > 1.0 THEN 1.000
							            WHEN r.PearsonsR < -1.0 THEN -1.000
							            ELSE r.PearsonsR
							            END 
		,IsStatisticallySignificant = IIF(ABS(r.PearsonsR) >= crit.CriticalValue,1,0)
		,PearsonsRStates	        = ST.PearsonsRStates
	INTO #results				 
	FROM @results r
	INNER JOIN dbo.DimCategoryItem c1 ON r.RecordLabel1 = c1.PID
	INNER JOIN dbo.DimCategoryItem c2 ON r.RecordLabel2 = c2.PID
	INNER JOIN @resultsRespondentCount resp ON  r.RecordLabel1 = resp.RecordLabel1 AND r.RecordLabel2 = resp.RecordLabel2
	OUTER APPLY dbo.tvf_GetPearsonCriticalValue('95',resp.RespondentCount - 2) crit
	CROSS APPLY reporting.tvfGetPearsonsRStates(r.PearsonsR, crit.CriticalValue) ST
	WHERE PearsonsR IS NOT NULL

	IF NOT EXISTS (SELECT 1 FROM dbo.CorrelationGroupFilter WHERE GroupFilter = @groupsorted)
		INSERT INTO dbo.CorrelationGroupFilter VALUES(@groupsorted);

	INSERT INTO dbo.CorrelationOPToOPCacheResult
	SELECT
		CorrelationGroupFilterID = (SELECT CorrelationGroupFilterID FROM dbo.CorrelationGroupFilter WHERE GroupFilter = @groupsorted)
		,SurveyKey1 = SurveyKey1
		,SurveyKey2 = SurveyKey2
		,CategoryID1 = @CategoryID1
		,CategoryID2 = @CategoryID2
		,PID1 = PID1
		,PID2 = PID2
		,PearsonsR = PearsonsR
		,IsStatisticallySignificant = IsStatisticallySignificant
		,RespondentCount = RespondentCount
		,PearsonsRStates = PearsonsRStates
	FROM #results;

	SELECT
		SurveyName1
		,RecordLabel1
		,SurveyName2
		,RecordLabel2
		,Category1
		,Category2
		,RespondentCount
		,PearsonsR				
		,IsStatisticallySignificant
		,PearsonsRStates
	FROM #results;

END;
GO