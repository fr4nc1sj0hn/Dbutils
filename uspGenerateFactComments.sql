CREATE PROCEDURE [dbo].[uspGenerateFactComments]
AS
BEGIN
	DECLARE @SurveyKey INT;

	SELECT @SurveyKey = s.SurveyKey
	FROM dbo.dimSurvey s
	INNER JOIN staging.SurveyMetadata stg ON s.SurveyYear = stg.SurveyYear
			AND s.SurveyVersion = stg.SurveyVersion;
	SELECT @SurveyKey;

	DECLARE @ClientID INT = CAST((SELECT ConfigValue FROM staging.Config WHERE ConfigName = 'ClientID') AS INT);
	DECLARE @clientIDN VARCHAR(20) = cast(@ClientID as  VARCHAR(20))
	

	;WITH cte AS
	(
		SELECT
			RespondentID,
			QuestionID,
			CommentCategory,
			IIF(LEFT(Comment,1) = '"',SUBSTRING(Comment,2,LEN(Comment) - 2),Comment) AS Comment,
			IIF
			(
				(LEN(RespondentID) <> 32 OR LOWER(RespondentID) LIKE '%[^0-9a-f]%'),
				CONVERT(
					NVARCHAR(MAX),
					HASHBYTES(
						'MD5', 
						CONCAT(
							HASHBYTES(
								'MD5',
								CAST(@clientIDN AS	VARCHAR(20))
							),
							UPPER(CAST(RespondentID AS NVARCHAR(20)))
						)
					),
					2
				),
				RespondentID
			)	AS RespondentIDHashed
		FROM staging.Comments
	)
	INSERT INTO dbo.FactComments(RespondentKey,SurveyKey,CommentCategoryID,QuestionKey,Comment,CreatedDate,IsDeleted)
	SELECT 
		RespondentKey,
		@surveykey AS SurveyKey,
		cat.CategoryID,
		cq.QuestionKey,
		stg.Comment,
		GETDATE() AS CreatedDate,
		0 AS IsDeleted
	FROM cte stg
	INNER JOIN dbo.CommentCategory cat ON stg.CommentCategory = cat.Category
	INNER JOIN 
	(
		SELECT 
			QuestionID,
			IIF(LEFT(QuestionText,1) = '"',SUBSTRING(QuestionText,2,LEN(QuestionText) - 2),QuestionText) AS QuestionText FROM staging.questions 
	)q ON stg.QuestionID = q.QuestionID
	INNER JOIN dbo.CommentQuestion cq ON q.QuestionText = cq.QuestionText
	INNER JOIN dbo.DimRespondent resp ON resp.RespondentID = stg.RespondentIDHashed
END;
GO