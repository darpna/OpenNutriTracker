import 'package:opennutritracker/features/custom_portion/domain/repository/custom_portion_repository.dart';

class DeleteCustomPortionUsecase {
  final CustomPortionRepository _repository;

  DeleteCustomPortionUsecase(this._repository);

  Future<void> deleteCustomPortion(String id) => _repository.delete(id);
}
