import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

/// Transaction-local number allocation primitive for K06's trusted Submit
/// effect. Call only after authentication, permission checks, and receipt
/// replay resolution, using the same transaction that writes the document.
/// The forced row-security policy also requires the active submit context.
class PostgresDocumentNumberAllocator {
  const PostgresDocumentNumberAllocator();

  Future<String> allocate({
    required pg.TxSession transaction,
    required String tenantId,
    required String companyId,
    required String branchId,
    required String moduleId,
    required String docType,
    required DocumentNamingSeries series,
  }) async {
    final rows = await transaction.execute(
      pg.Sql.named('''
        INSERT INTO public.ventio_document_number_series
          (tenant_id,company_id,branch_id,module_id,doc_type,series_id,
           prefix,padding,next_number)
        VALUES
          (@tenant,@company,@branch,@module,@doctype,@series,
           @prefix,@padding,2)
        ON CONFLICT
          (tenant_id,company_id,branch_id,module_id,doc_type,series_id)
        DO UPDATE SET next_number=public.ventio_document_number_series.next_number+1
        WHERE public.ventio_document_number_series.prefix=EXCLUDED.prefix
          AND public.ventio_document_number_series.padding=EXCLUDED.padding
        RETURNING next_number-1
      '''),
      parameters: {
        'tenant': tenantId,
        'company': companyId,
        'branch': branchId,
        'module': moduleId,
        'doctype': docType,
        'series': series.seriesId,
        'prefix': series.prefix,
        'padding': series.padding,
      },
    );
    if (rows.length != 1 || rows.single[0] is! int) {
      throw StateError(
        'The numbering series was changed after its first allocation.',
      );
    }
    final number = rows.single[0] as int;
    if (number < 1) throw StateError('The numbering counter is invalid.');
    return series.formatNumber(number);
  }
}
