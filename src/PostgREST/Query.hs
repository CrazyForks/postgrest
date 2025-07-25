{-# LANGUAGE NamedFieldPuns  #-}
{-# LANGUAGE RecordWildCards #-}
-- TODO: This module shouldn't depend on SchemaCache
module PostgREST.Query
  ( Query (..)
  , QueryResult (..)
  , query
  , getSQLQuery
  ) where

import qualified Data.Aeson                        as JSON
import qualified Data.Aeson.KeyMap                 as KM
import qualified Data.ByteString                   as BS
import qualified Data.HashMap.Strict               as HM
import qualified Data.Set                          as S
import qualified Hasql.Decoders                    as HD
import qualified Hasql.DynamicStatements.Snippet   as SQL (Snippet)
import qualified Hasql.DynamicStatements.Statement as SQL
import qualified Hasql.Session                     as SQL (Session)
import qualified Hasql.Transaction                 as SQL
import qualified Hasql.Transaction.Sessions        as SQL

import qualified PostgREST.Error              as Error
import qualified PostgREST.Query.PreQuery     as PreQuery
import qualified PostgREST.Query.QueryBuilder as QueryBuilder
import qualified PostgREST.Query.Statements   as Statements
import qualified PostgREST.SchemaCache        as SchemaCache


import PostgREST.ApiRequest              (ApiRequest (..))
import PostgREST.ApiRequest.Preferences  (PreferCount (..),
                                          PreferHandling (..),
                                          PreferMaxAffected (..),
                                          PreferTransaction (..),
                                          Preferences (..),
                                          shouldCount)
import PostgREST.ApiRequest.Types        (Mutation (..))
import PostgREST.Auth.Types              (AuthResult (..))
import PostgREST.Config                  (AppConfig (..),
                                          OpenAPIMode (..))
import PostgREST.Error                   (Error)
import PostgREST.MediaType               (MediaType (..))
import PostgREST.Plan                    (ActionPlan (..),
                                          CallReadPlan (..),
                                          CrudPlan (..),
                                          DbActionPlan (..),
                                          InfoPlan (..),
                                          InspectPlan (..))
import PostgREST.Plan.MutatePlan         (MutatePlan (..))
import PostgREST.Query.Statements        (ResultSet (..))
import PostgREST.SchemaCache             (SchemaCache (..))
import PostgREST.SchemaCache.Identifiers (QualifiedIdentifier (..))
import PostgREST.SchemaCache.Routine     (Routine (..), RoutineMap)
import PostgREST.SchemaCache.Table       (TablesMap)

import Protolude hiding (Handler)

type DbHandler = ExceptT Error SQL.Transaction

data Query
  = DbQuery {
      dqIsoLevel    :: SQL.IsolationLevel
    , dqTxMode      :: SQL.Mode
    , dqDbHandler   :: DbHandler QueryResult
    , dqTransaction :: SQL.IsolationLevel -> SQL.Mode -> SQL.Transaction (Either Error QueryResult) -> SQL.Session (Either Error QueryResult)
    , dqSQL         :: ByteString
    }
  | NoDbQuery QueryResult

data QueryResult
  = DbCrudResult  CrudPlan ResultSet
  | DbCallResult  CallReadPlan  ResultSet
  | MaybeDbResult InspectPlan  (Maybe (TablesMap, RoutineMap, Maybe Text))
  | NoDbResult    InfoPlan

query :: AppConfig -> AuthResult -> ApiRequest -> ActionPlan -> SchemaCache -> Query
query _ _ _ (NoDb x) _ = NoDbQuery $ NoDbResult x
query config AuthResult{..} apiReq (Db plan) sCache =
  DbQuery isoLvl txMode dbHandler transaction mainSQLQuery
  where
    transaction = if prepared then SQL.transaction else SQL.unpreparedTransaction
    prepared = configDbPreparedStatements config
    isoLvl = planIsoLvl config authRole plan
    txMode = planTxMode plan
    (mainActionQuery, mainSQLQuery) = actionQuery plan config apiReq sCache
    dbHandler = do
      runTxVarQuery plan config authClaims authRole apiReq
      runPreReqQuery config
      mainActionQuery

planTxMode :: DbActionPlan -> SQL.Mode
planTxMode (DbCrud x)  = pTxMode x
planTxMode (DbCall x)  = crTxMode x
planTxMode (MaybeDb x) = ipTxmode x

planIsoLvl :: AppConfig -> ByteString -> DbActionPlan -> SQL.IsolationLevel
planIsoLvl AppConfig{configRoleIsoLvl} role actPlan = case actPlan of
  DbCall CallReadPlan{crProc} -> fromMaybe roleIsoLvl $ pdIsoLvl crProc
  _                           -> roleIsoLvl
  where
    roleIsoLvl = HM.findWithDefault SQL.ReadCommitted role configRoleIsoLvl

-- TODO: Generate the Hasql Statement in a diferent module after the OpenAPI functionality is removed
actionQuery :: DbActionPlan -> AppConfig -> ApiRequest -> SchemaCache -> (DbHandler QueryResult, ByteString)
actionQuery (DbCrud plan@WrappedReadPlan{..}) conf@AppConfig{..} apiReq@ApiRequest{iPreferences=Preferences{..}} _ =
  (mainActionQuery, mainSQLQuery)
  where
    countQuery = QueryBuilder.readPlanToCountQuery wrReadPlan
    (result, mainSQLQuery) = Statements.prepareRead
      (QueryBuilder.readPlanToQuery wrReadPlan)
      (if preferCount == Just EstimatedCount then
         -- LIMIT maxRows + 1 so we can determine below that maxRows was surpassed
         QueryBuilder.limitedQuery countQuery ((+ 1) <$> configDbMaxRows)
       else
         countQuery
      )
      (shouldCount preferCount)
      wrMedia
      wrHandler
      configDbPreparedStatements
    mainActionQuery = do
      resultSet <- lift $ SQL.statement mempty result
      failNotSingular wrMedia resultSet
      optionalRollback conf apiReq
      DbCrudResult plan <$> resultSetWTotal conf apiReq resultSet countQuery

actionQuery (DbCrud plan@MutateReadPlan{..}) conf@AppConfig{..} apiReq@ApiRequest{iPreferences=Preferences{..}} _ =
  (mainActionQuery, mainSQLQuery)
  where
    (isPut, isInsert, pkCols) = case mrMutatePlan of {Insert{where_,insPkCols} -> ((not . null) where_, True, insPkCols); _ -> (False,False, mempty);}
    (result, mainSQLQuery) = Statements.prepareWrite
      (QueryBuilder.readPlanToQuery mrReadPlan)
      (QueryBuilder.mutatePlanToQuery mrMutatePlan)
      isInsert
      isPut
      mrMedia
      mrHandler
      preferRepresentation
      preferResolution
      pkCols
      configDbPreparedStatements
    failMutation resultSet = case mrMutation of
      MutationCreate -> do
        failNotSingular mrMedia resultSet
      MutationUpdate -> do
        failNotSingular mrMedia resultSet
        failExceedsMaxAffectedPref (preferMaxAffected,preferHandling) resultSet
      MutationSingleUpsert -> do
        failPut resultSet
      MutationDelete -> do
        failNotSingular mrMedia resultSet
        failExceedsMaxAffectedPref (preferMaxAffected,preferHandling) resultSet
    mainActionQuery = do
      resultSet <- lift $ SQL.statement mempty result
      failMutation resultSet
      optionalRollback conf apiReq
      pure $ DbCrudResult plan resultSet

actionQuery (DbCall plan@CallReadPlan{..}) conf@AppConfig{..} apiReq@ApiRequest{iPreferences=Preferences{..}} _ =
  (mainActionQuery, mainSQLQuery)
  where
    (result, mainSQLQuery) = Statements.prepareCall
      crProc
      (QueryBuilder.callPlanToQuery crCallPlan)
      (QueryBuilder.readPlanToQuery crReadPlan)
      (QueryBuilder.readPlanToCountQuery crReadPlan)
      (shouldCount preferCount)
      crMedia
      crHandler
      configDbPreparedStatements
    mainActionQuery = do
      resultSet <- lift $ SQL.statement mempty result
      optionalRollback conf apiReq
      failNotSingular crMedia resultSet
      failExceedsMaxAffectedPref (preferMaxAffected,preferHandling) resultSet
      pure $ DbCallResult plan resultSet

actionQuery (MaybeDb plan@InspectPlan{ipSchema=tSchema}) AppConfig{..} _ sCache =
  (mainActionQuery, mempty)
  where
    mainActionQuery = lift $
      case configOpenApiMode of
        OAFollowPriv -> do
          tableAccess <- SQL.statement [tSchema] (SchemaCache.accessibleTables configDbPreparedStatements)
          MaybeDbResult plan . Just <$> ((,,)
                (HM.filterWithKey (\qi _ -> S.member qi tableAccess) $ SchemaCache.dbTables sCache)
            <$> SQL.statement ([tSchema], configDbHoistedTxSettings) (SchemaCache.accessibleFuncs configDbPreparedStatements)
            <*> SQL.statement tSchema (SchemaCache.schemaDescription configDbPreparedStatements))
        OAIgnorePriv ->
          (MaybeDbResult plan . Just) . (,,)
                (HM.filterWithKey (\(QualifiedIdentifier sch _) _ ->  sch == tSchema) $ SchemaCache.dbTables sCache)
                (HM.filterWithKey (\(QualifiedIdentifier sch _) _ ->  sch == tSchema) $ SchemaCache.dbRoutines sCache)
            <$> SQL.statement tSchema (SchemaCache.schemaDescription configDbPreparedStatements)
        OADisabled ->
          pure $ MaybeDbResult plan Nothing

-- Makes sure the querystring pk matches the payload pk
-- e.g. PUT /items?id=eq.1 { "id" : 1, .. } is accepted,
-- PUT /items?id=eq.14 { "id" : 2, .. } is rejected.
-- If this condition is not satisfied then nothing is inserted,
-- check the WHERE for INSERT in QueryBuilder.hs to see how it's done
failPut :: ResultSet -> DbHandler ()
failPut RSPlan{} = pure ()
failPut RSStandard{rsQueryTotal=queryTotal} =
  when (queryTotal /= 1) $ do
    lift SQL.condemn
    throwError $ Error.ApiRequestError Error.PutMatchingPkError

resultSetWTotal :: AppConfig -> ApiRequest -> ResultSet -> SQL.Snippet -> DbHandler ResultSet
resultSetWTotal _ _ rs@RSPlan{} _ = return rs
resultSetWTotal AppConfig{..} ApiRequest{iPreferences=Preferences{..}} rs@RSStandard{rsTableTotal=tableTotal} countQuery =
  case preferCount of
    Just PlannedCount -> do
      total <- explain
      return rs{rsTableTotal=total}
    Just EstimatedCount ->
      if tableTotal > (fromIntegral <$> configDbMaxRows) then do
        total <- max tableTotal <$> explain
        return rs{rsTableTotal=total}
      else
        return rs
    Just ExactCount ->
      return rs
    Nothing ->
      return rs
  where
    explain =
      lift . SQL.statement mempty . Statements.preparePlanRows countQuery $
        configDbPreparedStatements

-- |
-- Fail a response if a single JSON object was requested and not exactly one
-- was found.
failNotSingular :: MediaType -> ResultSet -> DbHandler ()
failNotSingular _ RSPlan{} = pure ()
failNotSingular mediaType RSStandard{rsQueryTotal=queryTotal} =
  when (elem mediaType [MTVndSingularJSON True, MTVndSingularJSON False] && queryTotal /= 1) $ do
    lift SQL.condemn
    throwError $ Error.ApiRequestError . Error.SingularityError $ toInteger queryTotal

failExceedsMaxAffectedPref :: (Maybe PreferMaxAffected, Maybe PreferHandling) -> ResultSet -> DbHandler ()
failExceedsMaxAffectedPref (Nothing,_) _ = pure ()
failExceedsMaxAffectedPref _ RSPlan{} = pure ()
failExceedsMaxAffectedPref (Just (PreferMaxAffected n), handling) RSStandard{rsQueryTotal=queryTotal} = when ((queryTotal > n) && (handling == Just Strict)) $ do
  lift SQL.condemn
  throwError $ Error.ApiRequestError . Error.MaxAffectedViolationError $ toInteger queryTotal

-- | Set a transaction to roll back if requested
optionalRollback :: AppConfig -> ApiRequest -> DbHandler ()
optionalRollback AppConfig{..} ApiRequest{iPreferences=Preferences{..}} = do
  lift $ when (shouldRollback || (configDbTxRollbackAll && not shouldCommit)) $ do
    SQL.sql "SET CONSTRAINTS ALL IMMEDIATE"
    SQL.condemn
  where
    shouldCommit =
      preferTransaction == Just Commit
    shouldRollback =
      preferTransaction == Just Rollback

runTxVarQuery :: DbActionPlan -> AppConfig -> KM.KeyMap JSON.Value -> BS.ByteString -> ApiRequest -> DbHandler ()
runTxVarQuery dbActPlan conf@AppConfig{..} claims role apireq = lift $
  SQL.statement mempty $ SQL.dynamicallyParameterized
    (PreQuery.txVarQuery dbActPlan conf claims role apireq)
    HD.noResult configDbPreparedStatements

runPreReqQuery :: AppConfig -> DbHandler ()
runPreReqQuery conf = lift $ traverse_ (SQL.statement mempty . stmt) (configDbPreRequest conf)
  where
    stmt req = SQL.dynamicallyParameterized
      (PreQuery.preReqQuery req)
      HD.noResult
      (configDbPreparedStatements conf)

getSQLQuery :: Query -> ByteString
getSQLQuery DbQuery{dqSQL} = dqSQL
getSQLQuery _              = mempty
