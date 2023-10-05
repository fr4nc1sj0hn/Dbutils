/**
	Summary:
		Generates individual Dimensions from the CQs
	Example:
		EXEC dbo.uspGenerateDimsFromCQs

	Returns: None
	
	Change History
	==============================================================
	5/18/2018	FRANC583	Initial Version
	1/17/2019	FRANC583	CPA-608
	2/4/2019	FRANC583	CPA-619
	03/26/2020	FRANC583	ETL Improvements
	02/19/2021	FRANC583	ETL OPtimization. Removed other Fact Tables and added Default Dimension Keys
**/
CREATE PROCEDURE [dbo].[uspGenerateDimsFromCQs]
AS
BEGIN
	SET NOCOUNT ON;
	DECLARE @CQChange AS INT = (SELECT ConfigValue FROM staging.Config WHERE ConfigName = 'CQ Change');

	DECLARE @SQL NVARCHAR(MAX) = ''


	DECLARE @names TABLE
	(
		ID			INT IDENTITY(1,1),
		CQName		NVARCHAR(100),
		CQNumber	INT,
		dimTable	NVARCHAR(100)
	)

	-- Get the list of Dimensions
	INSERT INTO @names SELECT CQName,CQNumber,dimTable FROM [staging].[CQList] WHERE CQNumber < 1000;

	DECLARE 
		@counter	INT = 1,
		@maxid		INT = (SELECT MAX(ID) FROM @names)

	WHILE @counter <= @maxid
	BEGIN
		DECLARE 
			@dimTable NVARCHAR(100),
			@CQName NVARCHAR(100),
			@CQNumber INT

		SELECT
			@dimTable = dimTable,
			@CQName = CQName,
			@CQNumber = CQNumber
		FROM @names WHERE ID = @counter;
		
		DECLARE @NoResponseLabel NVARCHAR(100) = N'';

		IF @dimTable = 'Turnover'
			SET @NoResponseLabel = 'Involuntary Leaver'
		ELSE
			SET @NoResponseLabel = 'No Response'


		SET @SQL = CAST(N'
		IF OBJECT_ID(''dbo.dim' + CAST(@dimTable AS NVARCHAR(MAX)) + ''') IS NULL
		BEGIN
			CREATE TABLE dbo.dim' + CAST(@dimTable AS NVARCHAR(MAX)) + N' 
			(
				GroupKey			BIGINT NOT NULL,
				CodingResponseID	INT,
				CodingLabel			NVARCHAR(2000),
				ParentGroupKey		BIGINT,
				LastChangedBy		NVARCHAR(100),
				LastChangeDate		DATE,
				StartDate			DATE,
				EndDate				DATE,
				IsActive			BIT
			);

			INSERT INTO dbo.dim' + CAST(@dimTable AS NVARCHAR(MAX)) + N'
			SELECT 
				GroupKey,
				CodingResponseID,
				CodingLabel,
				ParentGroupKey,
				LastChangedBy,
				LastChangeDate,
				StartDate,
				EndDate,
				IsActive
			FROM dbo.dimGroup 
			WHERE ParentCQName = ''' + CAST(@CQName AS NVARCHAR(MAX)) + N'''
			
			CREATE CLUSTERED INDEX PK_dim'  + CAST(@dimTable AS NVARCHAR(MAX)) + N' ON dbo.dim' + CAST(@dimTable AS NVARCHAR(MAX)) + N'(GroupKey);


			CREATE NONCLUSTERED COLUMNSTORE INDEX NCI_'  + CAST(@dimTable AS NVARCHAR(MAX)) + N' ON dbo.dim' + CAST(@dimTable AS NVARCHAR(MAX)) + N'(GroupKey,CodingResponseID,CodingLabel,ParentGroupKey);

			-- Dummy Dim Row for Fact rows without dimension assignment

			INSERT INTO dbo.dim' + CAST(@dimTable AS NVARCHAR(MAX)) + '
			(	
				GroupKey,
				CodingResponseID, 
				CodingLabel, 
				ParentGroupKey,
				LastChangedBy,
				LastChangeDate,
				StartDate,
				EndDate,
				IsActive

			)
			VALUES
			(
				-1,
				-1,
				''' + @NoResponseLabel + N''',
				NULL,
				NULL,
				NULL,
				NULL,
				NULL,
				1
			);
				
			IF OBJECT_ID(''dbo.FactCodingResponse'') IS NOT NULL
			BEGIN
				ALTER TABLE dbo.FactCodingResponse
				ADD dim' + CAST(@dimTable AS NVARCHAR(MAX)) + N'Key BIGINT NULL
				CONSTRAINT DF_FactCodingResponse_dim' + CAST(@dimTable AS NVARCHAR(MAX)) + N'Key
				DEFAULT (-1)
				WITH VALUES;
			END
		END
		ELSE
		BEGIN
			IF (SELECT ConfigValue FROM staging.Config WHERE ConfigName = ''CQ Change'') = 1
			BEGIN
				
				IF OBJECT_ID(N''tempdb..#groupmembers'') IS NOT NULL
					DROP TABLE #groupmembers;

				;WITH cte AS
				(
					SELECT 
						GroupKey,
						CodingResponseID,
						CodingLabel,
						ParentGroupKey,
						LastChangedBy,
						LastChangeDate,
						StartDate,
						EndDate,
						IsActive
					FROM dbo.dimGroup 
					WHERE ParentCQName = ''' + CAST(@CQName AS NVARCHAR(MAX)) + N'''
				)
				SELECT 
					* 
				INTO #groupmembers
				FROM cte;

				-- Updates
				UPDATE dim
				SET 
					dim.IsActive		=  u.IsActive,
					dim.LastChangedBy	= SYSTEM_USER,
					dim.LastChangeDate	= GETDATE(),
					dim.EndDate			= GETDATE()
				FROM dbo.dim' + CAST(@dimTable AS NVARCHAR(MAX)) + N' dim
				INNER JOIN #groupmembers u ON dim.GroupKey = u.GroupKey
				WHERE u.IsActive <> dim.IsActive


				-- New Data
				INSERT INTO dbo.dim' + CAST(@dimTable AS NVARCHAR(MAX)) + N'
				SELECT
					grp.GroupKey,
					grp.CodingResponseID,
					grp.CodingLabel,
					grp.ParentGroupKey,
					grp.LastChangedBy,
					grp.LastChangeDate,
					grp.StartDate,
					grp.EndDate,
					grp.IsActive
				FROM #groupmembers grp
				LEFT JOIN dbo.dim' + CAST(@dimTable AS NVARCHAR(MAX)) + N' dim ON grp.GroupKey = dim.GroupKey
				WHERE dim.GroupKey IS NULL;
			END
		END
		' AS NVARCHAR(MAX))
	
		EXEC sp_executesql @SQL;

		SET @counter = @counter + 1;
	END
END;
GO