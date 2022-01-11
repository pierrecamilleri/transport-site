Mox.defmock(Transport.ExAWS.Mock, for: ExAws.Behaviour)
Mox.defmock(Transport.HTTPoison.Mock, for: HTTPoison.Base)
Mox.defmock(Validation.Validator.Mock, for: Shared.Validation.Validator)
Mox.defmock(Shared.Validation.GBFSValidator.Mock, for: Shared.Validation.GBFSValidator.Wrapper)
Mox.defmock(Transport.Rambo.Mock, for: Transport.RamboLauncher)
Mox.defmock(Transport.Notifications.FetcherMock, for: Transport.Notifications.Fetcher)
Mox.defmock(Transport.Shared.GBFSMetadata.Mock, for: Transport.Shared.GBFSMetadata.Wrapper)
Mox.defmock(Transport.AvailabilityChecker.Mock, for: Transport.AvailabilityChecker.Wrapper)
Mox.defmock(Shared.Validation.JSONSchemaValidator.Mock, for: Shared.Validation.JSONSchemaValidator.Wrapper)
Mox.defmock(Shared.Validation.TableSchemaValidator.Mock, for: Shared.Validation.TableSchemaValidator.Wrapper)
Mox.defmock(Transport.Shared.Schemas.Mock, for: Transport.Shared.Schemas.Wrapper)
